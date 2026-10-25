// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import os
import StoreKit
import TaoolCore

/// Talks to taool: which experiments have ended (`RefreshSchedule`), and the exposures, goals
/// and purchases the store has queued. Nothing here blocks the app: a report that fails stays
/// queued for the next time the app comes to the foreground.
actor ExperimentReporter {
    static let shared: ExperimentReporter = ExperimentReporter(store: .shared)

    private let store: ExperimentStore
    private let session: URLSession
    private let baseURL: URL
    private let appTransaction: @Sendable () async -> AppTransactionFacts?
    private let log = Logger(subsystem: "TaoolKit", category: "experiments")

    private var key: String?
    private var bundleID: String?
    private var environment: String?
    /// When which experiments ended was last asked this launch, whatever came of it.
    private var winnersAskedAt: Date?
    private var transactionsCollected = false
    private var flushScheduled = false
    private var flushing = false
    private var scenes = ScenesInUse()

    /// `appTransaction`: StoreKit's unless a test says otherwise.
    init(store: ExperimentStore, session: URLSession = Kit.session, baseURL: URL = Kit.baseURL,
         appTransaction: @escaping @Sendable () async -> AppTransactionFacts? = { await AppTransactionFacts.read() }) {
        self.store = store
        self.session = session
        self.baseURL = baseURL
        self.appTransaction = appTransaction
    }

    /// A scene became active (`TaoolExperimentsModifier`). The first, as the app comes to the
    /// foreground, shows what taool said that waited, then asks again (`activate`), what it says
    /// waiting for the next time; in a task of its own, so the scene going inactive never
    /// cancels it halfway. Another window, or coming back from Control Center, changes nothing.
    func becameActive(scene: UUID, key: String, bundleID: String?) {
        guard scenes.becameActive(scene) else { return }
        store.showWaiting()
        Task { await activate(key: key, bundleID: bundleID) }
    }

    /// A scene went to the background or closed.
    func left(scene: UUID) {
        _ = scenes.left(scene)
    }

    /// As the app comes to the foreground: learn which experiments ended, pick up purchases
    /// made since the first exposure, and report what's queued.
    func activate(key: String, bundleID: String?, now: Date = .now) async {
        guard !key.isEmpty else {
            Notice.once("No taool key, so experiments aren't reported. The key is on the taool app's TaoolKit page.", log: log)
            return
        }
        ServerKeyGuard.check(key, log: log)
        self.key = key
        self.bundleID = bundleID ?? Bundle.main.bundleIdentifier
        await refreshWinners(now: now)
        await collectTransactions()
        await flush()
    }

    /// Something new to report: wait a moment so a screen's experiments, goals and a purchase
    /// go in one request. Calls while one is waiting join it.
    func flushSoon() async {
        guard !flushScheduled else { return }
        flushScheduled = true
        try? await Task.sleep(for: .seconds(2))
        flushScheduled = false
        await flush()
    }

    private struct WinnersBody: Decodable {
        let winners: [Counted]
    }

    /// An experiment and a variant: an ended one's winner, or the variant that counts for a user.
    private struct Counted: Decodable {
        let experiment: String
        let variant: String
    }

    func refreshWinners(now: Date = .now) async {
        guard let key, let bundleID,
              RefreshSchedule.isDue(askedAt: winnersAskedAt, fetchedAt: store.winnersFetchedAt, now: now) else { return }
        winnersAskedAt = now

        var url = baseURL.appending(path: "v1/experiments/\(bundleID)")
        url.append(queryItems: [URLQueryItem(name: "key", value: key)])
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                let body = try Kit.decoder.decode(WinnersBody.self, from: data)
                store.setWinners(Self.byExperiment(body.winners), fetchedAt: now)
            case 404:
                unknownApp(bundleID)
                store.keepWinners(fetchedAt: now)
            default:
                throw URLError(.badServerResponse)
            }
        } catch {
            log.info("Couldn't ask taool which experiments ended, using the last answer: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func byExperiment(_ list: [Counted]) -> [String: String] {
        Dictionary(list.map { ($0.experiment, $0.variant) }, uniquingKeysWith: { first, _ in first })
    }

    /// Purchases from StoreKit's history on the device, once a launch: the ones
    /// `TaoolExperiments.record` didn't see (renewals, other devices, a missed call). The store
    /// keeps those that began since the first exposure.
    private func collectTransactions() async {
        guard !transactionsCollected, store.firstExposureAt != nil else { return }
        transactionsCollected = true
        for await result in Transaction.all {
            let transaction = result.unsafePayloadValue
            store.addTransaction(id: transaction.id, purchase: transaction.originalID, jws: result.jwsRepresentation,
                                 startedAt: transaction.originalPurchaseDate)
        }
    }

    private struct EventsBody: Encodable {
        let personId: String
        let previousPersonId: String?
        let environment: String
        let exposures: [ExperimentStore.Exposure]
        let goals: [ExperimentStore.Goal]
        let transactions: [String]
    }

    private struct EventsAnswer: Decodable {
        let variants: [Counted]
    }

    private enum Outcome { case sent([String: String]), refused, failed }

    /// Sends what's queued, a request at a time, until it's all sent or a request fails.
    /// First, who the user is and where this build came from: StoreKit is asked once a launch until it has said.
    func flush() async {
        guard let key, let bundleID, !flushing else { return }
        flushing = true
        defer { flushing = false }
        guard let environment = await identify() else { return }
        while true {
            let batch = store.nextBatch()
            if batch.isEmpty { return }
            let body = EventsBody(personId: batch.person.id, previousPersonId: batch.previousPersonId, environment: environment,
                                  exposures: batch.exposures, goals: batch.goals, transactions: batch.transactions.map(\.jws))
            switch await send(body, key: key, bundleID: bundleID) {
            case .sent(let counted):
                store.adopt(counted)
                store.remove(batch)
            case .refused:
                store.remove(batch)
            case .failed:
                return
            }
        }
    }

    private func send(_ body: EventsBody, key: String, bundleID: String) async -> Outcome {
        var url = baseURL.appending(path: "v1/experiments/\(bundleID)/events")
        url.append(queryItems: [URLQueryItem(name: "key", value: key)])
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try Kit.encoder.encode(body)
            let (data, response) = try await session.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                return .sent((try? Kit.decoder.decode(EventsAnswer.self, from: data)).map { Self.byExperiment($0.variants) } ?? [:])
            case 400:
                log.error("taool refused an experiment report as invalid, so it's dropped.")
                return .refused
            case 404:
                unknownApp(bundleID)
                return .failed
            default:
                return .failed
            }
        } catch {
            log.info("Couldn't report experiments to taool, will try again: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    private func unknownApp(_ bundleID: String) {
        Notice.once("taool doesn't know \(bundleID) for this key, so reports wait and the last winners stay. Is it one of your apps in taool, and is the key right?", log: log)
    }

    /// Where this build came from ("production", "sandbox" for TestFlight and development builds, or "xcode" for StoreKit
    /// testing) and Apple's ID for the user, from StoreKit, asked at each report until it has said. Without an answer
    /// (offline, or not signed in to the App Store), a debug build reports as the install, in the sandbox, and a later
    /// answer moves the install's activity onto the user; any other build's reports wait, since a TestFlight build
    /// guessed as the App Store's would count in live results.
    private func identify() async -> String? {
        if let environment { return environment }
        guard let app = await appTransaction() else {
            #if DEBUG
            return "sandbox"
            #else
            return nil
            #endif
        }
        store.setAppTransactionId(app.id)
        let environment = switch app.environment {
        case .production: "production"
        case .xcode: "xcode"
        default: "sandbox"
        }
        self.environment = environment
        return environment
    }
}
