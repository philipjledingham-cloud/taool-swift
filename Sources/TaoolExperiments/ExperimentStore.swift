// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import os
import TaoolCore

/// What this app knows about its experiments, kept in a file: who the user is, the variant
/// they got in each experiment, the winners taool last named, and what hasn't been reported
/// yet (exposures, goals and purchases). `variant` is synchronous, for `body`, so the state
/// sits behind a lock rather than in an actor.
///
/// **Who the user is**, the one ID variants are bucketed by and reports are counted by: the
/// developer's own user ID when the app passes one (`userID`, hashed here), else Apple's
/// appTransactionID (one per Apple Account and app, the same on every device and after a
/// reinstall), else, until StoreKit has said, this install's random ID.
final class ExperimentStore: @unchecked Sendable {
    static let shared: ExperimentStore = ExperimentStore(changed: { Task { await ExperimentReporter.shared.flushSoon() } })

    /// A purchase this long before the first exposure still counts: clocks drift.
    static let clockSkew: TimeInterval = 10 * 60
    /// Transactions sent per purchase: the first, and one renewal, which is how a trial that
    /// became paid shows. Every later renewal says nothing new.
    static let transactionsPerPurchase = 2

    struct Exposure: Codable, Equatable, Sendable {
        let experiment: String
        let variant: String
        /// Every variant in the code, in order: the first is the control.
        let variants: [String]
        let at: Date
    }

    /// One of the app's own goals, reached.
    struct Goal: Codable, Equatable, Sendable {
        let name: String
        let at: Date
    }

    struct PendingTransaction: Codable, Equatable, Sendable {
        let id: UInt64
        /// The signed transaction (`jwsRepresentation`), which taool verifies with Apple's certificates.
        let jws: String
    }

    /// Who a report is from.
    struct Person: Codable, Equatable, Sendable {
        let id: String
        /// The developer's own user ID (hashed): leaving it never merges, since the next user may be someone else.
        let isUser: Bool
    }

    /// What's due to be reported, at most one request's worth.
    struct Batch: Sendable {
        let person: Person
        /// The automatic ID this device reported as before, when it has moved on (a user signed
        /// in, or StoreKit answered late): taool moves that user onto `person`.
        let previousPersonId: String?
        let exposures: [Exposure]
        let goals: [Goal]
        let transactions: [PendingTransaction]
        var isEmpty: Bool { previousPersonId == nil && exposures.isEmpty && goals.isEmpty && transactions.isEmpty }
    }

    struct Saved: FileState {
        var installId = UUID()
        /// Apple's appTransactionID, once StoreKit has said.
        var appTransactionId: String?
        /// A SHA-256 of the developer's user ID while one is signed in.
        var userHash: String?
        /// Who this device last reported as, successfully.
        var reportedAs: Person?
        var assignments: [String: String] = [:]
        /// taool's variants for this user that differ from what this device shows, waiting for the app to come to the
        /// foreground (`showWaiting`).
        var adopted: [String: String] = [:]
        var exposedAt: [String: Date] = [:]
        var winners: [String: String] = [:]
        /// taool's latest winners, where they change what this device shows: waiting for the foreground (`showWaiting`).
        var nextWinners: [String: String]?
        var winnersFetchedAt: Date?
        var pendingExposures: [Exposure] = []
        var pendingGoals: [Goal] = []
        /// When each goal was last queued: it's queued again only after a newer exposure.
        var goalQueuedAt: [String: Date] = [:]
        var pendingTransactions: [PendingTransaction] = []
        /// The transactions queued so far, by the purchase (original transaction ID) they belong to.
        var queuedTransactions: [String: [UInt64]] = [:]

        var person: Person {
            if let userHash { return Person(id: userHash, isUser: true) }
            return Person(id: appTransactionId ?? installId.uuidString.lowercased(), isUser: false)
        }
    }

    /// What one report carries at most of each.
    static let maxExposures = 50, maxGoals = 50, maxTransactions = 20
    /// What taool counts at most of an experiment's variants.
    static let maxVariants = 10

    private let file: StateFile<Saved>
    private let changed: @Sendable () -> Void
    private let lock = NSLock()
    private let log = Logger(subsystem: "TaoolKit", category: "experiments")
    private var saved: Saved
    /// DEBUG only: variants shown without counting, from `TaoolExperiments.force`.
    private var forced: [String: String] = [:]

    /// `changed`: called when there's something new to report.
    init(file: StateFile<Saved> = .inAppSupport("experiments.json"), changed: @escaping @Sendable () -> Void = {}) {
        self.file = file
        self.changed = changed
        if let saved = file.read() {
            self.saved = saved
            // A launch is the app coming to the foreground, before any screen.
            showWaiting()
        } else {
            saved = Saved()
            save()
        }
    }

    var person: Person { lock.withLock { saved.person } }

    func setAppTransactionId(_ id: String) {
        lock.withLock {
            guard saved.appTransactionId != id else { return }
            saved.appTransactionId = id
            save()
        }
    }

    /// The developer's own ID for the signed-in user, or nil for none (then the automatic
    /// one). Only its SHA-256 is kept and sent. Signing in reports soon, so the user's
    /// earlier activity is moved over and their variants come back.
    func setUser(_ userID: String?) {
        let hashed = Kit.userID(userID).map(Hash.sha256)
        let signedIn = lock.withLock { () -> Bool in
            guard saved.userHash != hashed else { return false }
            saved.userHash = hashed
            save()
            return hashed != nil
        }
        if signedIn { changed() }
    }

    /// The variant to show: a forced one (DEBUG), else the winner, else the user's own.
    /// The first time they get their own, the exposure is queued for taool.
    func variant(experiment: String, variants: [String], now: Date = .now) -> String {
        let (name, exposed) = lock.withLock { () -> (String, Bool) in
            if let forced = forced[experiment], variants.contains(forced) { return (forced, false) }
            if let winner = saved.winners[experiment], variants.contains(winner) { return (winner, false) }

            let name = saved.assignments[experiment].flatMap { variants.contains($0) ? $0 : nil }
                ?? Self.bucket(experiment: experiment, person: saved.person.id, variants: variants)
            var dirty = saved.assignments[experiment] != name
            saved.assignments[experiment] = name
            // Checked once, when the first exposure would be queued: not on every read.
            var exposed = false
            if saved.exposedAt[experiment] == nil {
                if Self.isCodeName(experiment), variants.count <= Self.maxVariants, variants.allSatisfy(Self.isVariantName) {
                    saved.exposedAt[experiment] = now
                    saved.pendingExposures.append(Exposure(experiment: experiment, variant: name, variants: variants, at: now))
                    exposed = true
                    dirty = true
                } else {
                    Notice.once("\(experiment) isn't counted: an experiment's key needs letters, digits, \".\", \"_\" or \"-\" (up to 64), and its variants, at most \(Self.maxVariants), each a raw value up to 64 characters.", log: log, level: .error)
                }
            }
            if dirty { save() }
            return (name, exposed)
        }
        if exposed { changed() }
        return name
    }

    /// The same user always lands in the same variant of an experiment, on every device,
    /// and each experiment splits users independently of the others.
    static func bucket(experiment: String, person: String, variants: [String]) -> String {
        variants[Hash.bucket("\(experiment).\(person)", count: variants.count)]
    }

    /// taool's answer: the variants that count for this user, where another device (or
    /// this one before a reinstall or a sign-in) got there first. One this device hasn't
    /// shown is shown from now on; one that changes what it shows waits for the app to come
    /// to the foreground, so a screen in use never changes.
    func adopt(_ variants: [String: String]) {
        lock.withLock {
            let before = (saved.assignments, saved.adopted)
            for (experiment, variant) in variants {
                if let shown = saved.assignments[experiment] {
                    saved.adopted[experiment] = shown == variant ? nil : variant
                } else {
                    saved.assignments[experiment] = variant
                }
            }
            if before != (saved.assignments, saved.adopted) { save() }
        }
    }

    /// The app came to the foreground: what taool said that waited (the variants that count for this user, the winners)
    /// is shown from now on.
    func showWaiting() {
        lock.withLock {
            guard !saved.adopted.isEmpty || saved.nextWinners != nil else { return }
            saved.assignments.merge(saved.adopted) { _, counted in counted }
            saved.adopted = [:]
            if let next = saved.nextWinners { saved.winners = next }
            saved.nextWinners = nil
            save()
        }
    }

    /// What taool accepts as an experiment's key or a goal's name.
    static func isCodeName(_ name: String) -> Bool {
        (1...64).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// Up to 64 UTF-16 units, as taool counts them.
    static func isVariantName(_ name: String) -> Bool {
        (1...64).contains(name.utf16.count) && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    func force(experiment: String, variant: String) {
        lock.withLock { forced[experiment] = variant }
    }

    var winnersFetchedAt: Date? { lock.withLock { saved.winnersFetchedAt } }

    /// taool's answer, every ended experiment's winner. One this device hasn't shown is shown from now on; one that
    /// changes what it shows (a new winner, or none, the experiment run again) waits for the app to come to the
    /// foreground, so a screen in use never changes.
    func setWinners(_ winners: [String: String], fetchedAt: Date) {
        lock.withLock {
            for (experiment, winner) in winners where saved.winners[experiment] == nil && saved.assignments[experiment] == nil {
                saved.winners[experiment] = winner
            }
            saved.nextWinners = winners == saved.winners ? nil : winners
            saved.winnersFetchedAt = fetchedAt
            save()
        }
    }

    /// Asked, and taool doesn't know the app (removed from taool, say): the last winners stay, as offline, so an ended
    /// experiment never goes back to its split.
    func keepWinners(fetchedAt: Date) {
        lock.withLock {
            saved.winnersFetchedAt = fetchedAt
            save()
        }
    }

    /// Queues one of the app's goals, once per exposure: reaching it again before another
    /// experiment shows adds nothing. True when it's queued.
    @discardableResult
    func addGoal(_ name: String, now: Date = .now) -> Bool {
        guard Self.isCodeName(name) else {
            Notice.once("Goal \(name) isn't counted: a goal's name needs letters, digits, \".\", \"_\" or \"-\" (up to 64).", log: log, level: .error)
            return false
        }
        let added = lock.withLock { () -> Bool in
            guard let latest = saved.exposedAt.values.max() else { return false }
            if let queued = saved.goalQueuedAt[name], queued >= latest { return false }
            saved.goalQueuedAt[name] = now
            saved.pendingGoals.append(Goal(name: name, at: now))
            save()
            return true
        }
        if added { changed() }
        return added
    }

    /// When the first experiment showed here; purchases before it don't count.
    var firstExposureAt: Date? { lock.withLock { saved.exposedAt.values.min() } }

    /// Queues a purchase that began since the first exposure, once, and at most
    /// `transactionsPerPurchase` of its transactions. True when it's new. `startedAt` is the
    /// original purchase date, so a trial's renewal counts and the renewal of a subscription
    /// from before the experiment doesn't.
    @discardableResult
    func addTransaction(id: UInt64, purchase: UInt64, jws: String, startedAt: Date) -> Bool {
        let added = lock.withLock { () -> Bool in
            let queued = saved.queuedTransactions[String(purchase), default: []]
            guard let first = saved.exposedAt.values.min(),
                  startedAt >= first.addingTimeInterval(-Self.clockSkew),
                  !queued.contains(id), queued.count < Self.transactionsPerPurchase
            else { return false }
            saved.queuedTransactions[String(purchase)] = queued + [id]
            saved.pendingTransactions.append(PendingTransaction(id: id, jws: jws))
            save()
            return true
        }
        if added { changed() }
        return added
    }

    func nextBatch() -> Batch {
        lock.withLock {
            let person = saved.person
            // Moving off an automatic ID merges it into the new one; leaving a user's never does.
            let previous = saved.reportedAs.flatMap { $0.id != person.id && !$0.isUser ? $0.id : nil }
            return Batch(person: person, previousPersonId: previous,
                         exposures: Array(saved.pendingExposures.prefix(Self.maxExposures)),
                         goals: Array(saved.pendingGoals.prefix(Self.maxGoals)),
                         transactions: Array(saved.pendingTransactions.prefix(Self.maxTransactions)))
        }
    }

    /// Forgets a batch once taool has it, or has refused it for good, and remembers who it
    /// was from, so a merge is asked for once.
    func remove(_ batch: Batch) {
        lock.withLock {
            saved.pendingExposures.removeAll { batch.exposures.contains($0) }
            saved.pendingGoals.removeAll { batch.goals.contains($0) }
            saved.pendingTransactions.removeAll { batch.transactions.contains($0) }
            saved.reportedAs = batch.person
            save()
        }
    }

    /// Call with the lock held.
    private func save() {
        file.write(saved)
    }
}
