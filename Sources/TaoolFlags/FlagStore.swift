// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import Observation
import os
import StoreKit
import TaoolAnalytics
import TaoolCore

/// What TaoolFlags keeps on the device between launches: the app's flags as taool last sent them, the values picked for
/// this Apple Account and for each user who has signed in here, and what StoreKit last said about the device, so every
/// flag has its value the moment the app starts, offline or with taool out of reach.
struct FlagState: FileState, Equatable {
    var file: FlagFile?
    /// The values picked for this device's Apple Account, as taool last answered.
    var accountPicks: [FlagOverride] = []
    /// The values picked for each of the app's users who signed in here, by their ID, the latest last: another user's never
    /// apply, and a user's own come back as they sign in again, offline too.
    var userPicks: [UserPicks] = []
    var facts = FlagFacts()
    /// How many seconds the flags are asked for again after, as taool last said; nil until it has.
    var interval: Int?

    struct UserPicks: Codable, Sendable, Equatable {
        let userID: String
        var picks: [FlagOverride]
    }

    /// Users whose picks are kept at most.
    static let maxUsers = 5

    /// The picks that apply with `userID` signed in: the Apple Account's, with the user's own over them.
    func picks(for userID: String?) -> [String: JSONValue] {
        var picks = Dictionary(accountPicks.map { ($0.key, $0.value) }) { first, _ in first }
        for pick in userPicks.last(where: { $0.userID == userID })?.picks ?? [] { picks[pick.key] = pick.value }
        return picks
    }
}

extension StateFile where State == FlagState {
    static var standard: StateFile { inAppSupport("flags.json") }
}

/// The app's flags on this device: each one's value, worked out at launch from what was kept and again as the app comes
/// to the foreground, from the flags taool sends (asked for at each launch, then once `interval` has passed), the users
/// the developer picked (with the check-in, `FlagsCheckInListener`) and what the device knows about itself. Values are
/// worked out as of when the app last came to the foreground (`activeAt`), and change only then, as it leaves, or as a
/// user signs in or out, never in the middle of a screen.
@MainActor @Observable
final class FlagStore: FlagsCheckInListener {
    /// The one TaoolFlags uses.
    static let shared = FlagStore()

    /// How long the flags are asked for again after until taool has said, and the shortest and longest it may say.
    static let defaultInterval: TimeInterval = 60
    static let intervals: ClosedRange<TimeInterval> = 60...86_400

    /// Each flag's value as of `activeAt`, by key.
    private(set) var values: [String: JSONValue] = [:]
    /// DEBUG only: values set on this device, from `TaoolFlags.force`. Observed, so a view reading a flag redraws each
    /// time it's forced.
    private var forced: [String: Bool] = [:]

    @ObservationIgnored private var state: FlagState
    @ObservationIgnored private var saved: FlagState
    private let file: StateFile<FlagState>
    private let session: URLSession
    private let baseURL: URL
    private let readFacts: @MainActor () async -> FlagFacts
    /// The one check-in, whose key, bundle ID and user are the flags' too.
    private let checkIns: CheckIns
    /// When the app last came to the foreground: what every value is worked out as of, so a rollout's next step never
    /// lands in the middle of a screen.
    @ObservationIgnored private var activeAt = Date.now
    /// When the flags were last asked for, this launch: every launch asks once.
    @ObservationIgnored private var fetchedAt: Date?
    /// The flags' version taool last sent this launch (its ETag), so asking when nothing changed has a short answer.
    @ObservationIgnored private var etag: String?
    /// JSON flags' values as the app's code decoded them, by key and type, until the values change.
    @ObservationIgnored private var decoded: [String: Any] = [:]
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    private let log = Logger(subsystem: "TaoolKit", category: "flags")

    init(file: StateFile<FlagState> = .standard, session: URLSession = Kit.session, baseURL: URL = Kit.baseURL,
         checkIns: CheckIns = .shared, readFacts: @escaping @MainActor () async -> FlagFacts = { await FlagStore.deviceFacts() }) {
        self.file = file
        self.session = session
        self.baseURL = baseURL
        self.checkIns = checkIns
        self.readFacts = readFacts
        state = file.read() ?? FlagState()
        state.facts.readRunningApp()
        saved = state
        values = Self.values(state, userID: checkIns.userID, access: checkIns.accessProducts, now: activeAt)
    }

    func isOn(_ key: String) -> Bool {
        forced[key] ?? (values[key] == .bool(true))
    }

    /// A flag's value now, nil until the device has heard of it.
    func value(_ key: String) -> JSONValue? {
        forced[key].map(JSONValue.bool) ?? values[key]
    }

    /// A JSON flag's value decoded as `type`, decoded once until the values change; nil until the device has heard of it
    /// or when it isn't one.
    func decoded<Value: Decodable>(_ key: String, as type: Value.Type) -> Value? {
        // Read first, so a view reading it redraws as it changes.
        guard let value = value(key) else { return nil }
        let id = "\(key)\u{0}\(Value.self)"
        if let kept = decoded[id] as? Value { return kept }
        guard let data = try? Kit.encoder.encode(value), let result = try? Kit.decoder.decode(Value.self, from: data) else { return nil }
        decoded[id] = result
        return result
    }

    func force(_ key: String, _ on: Bool) {
        forced[key] = on
        decoded = [:]
    }

    /// The app came to the foreground (`CheckIns`, as its first scene becomes active): what the device knows about itself,
    /// the flags when they're due, then every value again. A call while one runs waits for it.
    func becameActive(now: Date = .now) async {
        if let refreshing {
            await refreshing.value
            return
        }
        let task = Task { await refresh(now: now) }
        refreshing = task
        await task.value
        refreshing = nil
    }

    /// The flags asked for and what the device knows read at once, neither waiting on the other; what's been bought only
    /// when a rule asks.
    private func refresh(now: Date) async {
        let fetchDue = fetchedAt.map { now.timeIntervalSince($0) >= interval } ?? true
        let fetching = fetchDue ? Task { await fetch(now: now) } : nil
        var facts = await readFacts()
        await fetching?.value
        if state.file?.asksForProducts == true { facts.products = await products() }
        state.facts = facts.keepingKnown(from: state.facts)
        save()
        activeAt = now
        recompute()
    }

    /// taool's answer to a check-in: the values picked for this Apple Account and for the user ID sent, each nil when taool
    /// didn't look, which keeps what was kept; the picks apply at once for the app becoming active or leaving and for a user
    /// signing in or out, any other's (a purchase's) waiting for the app to become active again. And how long to wait before
    /// asking for the flags again, kept for the next time it's due.
    func checkedIn(flags: [FlagOverride]?, userFlags: [FlagOverride]?, interval: Int?, userID: String?, transition: Bool) {
        if let interval { state.interval = interval }
        if let flags { state.accountPicks = flags }
        if let userFlags, let userID {
            state.userPicks.removeAll { $0.userID == userID }
            state.userPicks = Array((state.userPicks + [.init(userID: userID, picks: userFlags)]).suffix(FlagState.maxUsers))
        }
        save()
        if transition { recompute() }
    }

    /// Another user signed in, or no one: another user's picks stop and this one's kept picks apply, offline too.
    func userChanged() {
        recompute()
    }

    /// The app's flags from taool, as they are now, never an older copy kept on the device. Unchanged since the last ones
    /// this launch, or offline or not answered, the last ones stay.
    private func fetch(now: Date) async {
        // The key is checked by the check-in, which TaoolFlags always starts.
        let key = checkIns.key
        guard !key.isEmpty, let bundleID = checkIns.bundleID else { return }
        var url = baseURL.appending(path: "v1/flags/\(bundleID)")
        url.append(queryItems: [URLQueryItem(name: "key", value: key)])
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        // Asked, whatever comes of it: a failure waits the interval too.
        fetchedAt = now
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode {
            case 200:
                state.file = try Kit.decoder.decode(FlagFile.self, from: data)
                etag = http?.value(forHTTPHeaderField: "ETag")
            case 304:
                break
            case 404:
                Notice.once("taool doesn't know \(bundleID) for this key. Is it one of your apps in taool, and is the key right?", log: log)
            default:
                log.info("taool didn't send the app's flags; the last ones stay.")
            }
        } catch {
            log.info("Couldn't reach taool for the app's flags; the last ones stay.")
        }
    }

    /// How long the flags are asked for again after: what taool last said, within `intervals`, else `defaultInterval`.
    private var interval: TimeInterval {
        state.interval.map { min(max(TimeInterval($0), Self.intervals.lowerBound), Self.intervals.upperBound) } ?? Self.defaultInterval
    }

    /// Every value again, as of when the app last came to the foreground.
    private func recompute() {
        let next = Self.values(state, userID: checkIns.userID, access: checkIns.accessProducts, now: activeAt)
        guard next != values else { return }
        values = next
        decoded = [:]
    }

    /// Every flag's value from what's kept, with `userID` signed in: the flags taool sent, each worked out for this user,
    /// and a pick for a flag not in them yet (made since they were sent) as it was picked. `access`, TaoolPurchases' products
    /// that give access now, is what a subscribed rule goes by where the app has it, so it's whoever's signed in now.
    static func values(_ state: FlagState, userID: String?, access: Set<String>? = nil, now: Date) -> [String: JSONValue] {
        let picked = state.picks(for: userID)
        var values = picked
        var facts = state.facts
        facts.userID = FlagRules.canonical(userID)
        if let access { facts.products = access }
        for flag in state.file?.flags ?? [] {
            values[flag.key] = FlagRules.value(of: flag, picked: picked[flag.key], facts: facts, now: now)
        }
        return values
    }

    private func save() {
        guard state != saved else { return }
        file.write(state)
        saved = state
    }

    /// What the device knows about itself, read as the check-in reads it (`DeviceFacts`), so a rule and the taool app's
    /// view of the user see the same.
    static func deviceFacts() async -> FlagFacts {
        // Neither waits on the other: both ask StoreKit.
        async let territory = DeviceFacts.storefront()
        async let appTransaction = AppTransactionFacts.read()
        var facts = FlagFacts()
        facts.readRunningApp()
        facts.territory = await territory
        if let transaction = await appTransaction {
            (facts.appTransactionID, facts.isTestBuild, facts.downloadedAt) = (transaction.id, transaction.isTestBuild, transaction.downloadedAt)
        }
        return facts
    }

    /// The products that give access now, for a subscribed rule: in an app with TaoolPurchases, its own once it has read
    /// StoreKit, so taool's grants count too and a rule goes by what the app gives; else what StoreKit says.
    private func products() async -> Set<String> {
        if let access = checkIns.accessProducts { return access }
        var products = Set<String>()
        for await result in Transaction.currentEntitlements {
            // A non-renewing subscription stays here after it ends, so it gives nothing, as in TaoolPurchases.
            if case .verified(let transaction) = result, transaction.revocationDate == nil, transaction.productType != .nonRenewable {
                products.insert(transaction.productID)
            }
        }
        return products
    }
}

extension FlagFacts {
    /// The running app's own facts, which never wait: its version, OS, kind of device and language.
    @MainActor mutating func readRunningApp() {
        (appVersion, osVersion, deviceKind, language) = (RunningApp.version, RunningApp.osVersion, RunningApp.deviceKind, RunningApp.language)
    }
}
