// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import os
import TaoolCore

/// TaoolPurchases' side of the check-in: its part of each report, and what taool answered about it.
/// The check-in holds it weakly, and asks it before each report.
@MainActor
package protocol CheckInContributor: AnyObject {
    /// The strongest reason among what's queued, nil while nothing is; while something is, a check-in goes at once.
    var pendingReason: CheckInReason? { get }
    /// A check-in is about to go as the app becomes active, or for a new user (`userChanged`): read what's new, and for a
    /// new user all of it again.
    func prepare(now: Date, userChanged: Bool) async
    /// The next report's part, and the keys of the items it carries.
    func nextPart() -> (part: CheckInReport.Purchases, sent: [String])
    /// What became of the part that went: the keys `nextPart` gave with it.
    func checkedIn(_ outcome: CheckInOutcome, sent: [String])
    /// Another user is signed in (`CheckIns.userID`): what gives access changes with them at once.
    func userChanged()
    /// The products that give access now, as the app's `currentEntitlements` say, taool's grants too; nil until StoreKit
    /// has been read this launch, since a first launch or a reinstall has nothing kept.
    var accessProducts: Set<String>? { get }
}

/// TaoolFlags' side of the check-in: the values taool answered, and each user's own as they sign in and out.
@MainActor
package protocol FlagsCheckInListener: AnyObject {
    /// What taool answered: the values picked for this Apple Account (`flags`) and for the user ID it was sent
    /// (`userFlags`), each nil when taool didn't look (the device keeps what it had), how many seconds the flags are asked
    /// for again after (`interval`, nil when not said), and whether new values may show now (`transition`): the check-in
    /// went as the app became active or left, or for a new user.
    func checkedIn(flags: [FlagOverride]?, userFlags: [FlagOverride]?, interval: Int?, userID: String?, transition: Bool)
    /// Another user is signed in (`CheckIns.userID`): their own values apply at once.
    func userChanged()
    /// The app came to the foreground, its first scene becoming active: what's new applies now.
    func becameActive(now: Date) async
}

/// What became of a purchases part.
package enum CheckInOutcome: Sendable, Equatable {
    /// taool answered: about this Apple Account, its subscriptions that are another user's and its grants,
    /// each nil when not worked out (always, while the app isn't connected to Subscriptions).
    case answered(otherUser: [String]?, grants: [Grant]?)
    /// taool refused the report as malformed: sending it again won't help.
    case refused
}

/// The one check-in with taool, however many of TaoolKit's products the app links: TaoolAnalytics' modifier starts it,
/// and so do TaoolPurchases' and TaoolFlags', which add their parts. Each scene's modifiers call it as the app becomes
/// active and as it leaves, and calls that overlap make one check-in. Due at a cold launch and then only now and then
/// (`CheckInSchedule`), unless a purchase, a new user or the app asking needs one at once.
@MainActor
package final class CheckIns {
    /// The one TaoolKit uses.
    package static let shared = CheckIns()

    /// What started it, each with the level its code asks for and the user the app passes it.
    package enum Starter: Hashable, Sendable {
        case analytics, purchases, flags
    }

    struct Settings {
        var key = ""
        var bundleID: String?
        var levels: [Starter: TaoolAnalytics.Level] = [:]
        var userIDs: [Starter: String] = [:]
    }

    /// Opens closer together than this count as one: two windows becoming active, or a glance at
    /// Control Center.
    package static let sameOpen: TimeInterval = 60

    private(set) var settings = Settings()
    private(set) var state: CheckInState
    private let file: StateFile<CheckInState>
    private let client: CheckInClient
    private let appTransaction: @MainActor () async -> AppTransactionFacts?
    private weak var contributor: (any CheckInContributor)?
    private weak var flagsListener: (any FlagsCheckInListener)?
    private let log = Logger(subsystem: "TaoolKit", category: "check-in")
    private var checkInChain: Task<Bool, Never>?
    private var activating: Task<Void, Never>?
    private var leaving: Task<Void, Never>?
    /// The scenes that became active and haven't left since: the app is in use while any is.
    private var scenes = ScenesInUse()
    private var backgroundedAt: Date?
    /// The app has become active since it launched: the first time is a cold launch, which checks in (CheckInUrgency).
    private var launched = false
    /// How long after the first modifier the app has to pass who's signed in: until then its session may still be loading,
    /// so a nil leaves the saved user signed in, and A, nil, A changes nothing.
    private let sessionGrace: Duration
    private var settling: Task<Void, Never>?
    /// The session grace has passed.
    private var settled = false

    /// `appTransaction`: StoreKit's, read once a launch (`AppTransactionFacts.read()`), unless a test says otherwise.
    init(file: StateFile<CheckInState> = .standard, client: CheckInClient = CheckInClient(),
         appTransaction: @escaping @MainActor () async -> AppTransactionFacts? = { await AppTransactionFacts.read() },
         sessionGrace: Duration = .seconds(3)) {
        self.file = file
        self.client = client
        self.appTransaction = appTransaction
        self.sessionGrace = sessionGrace
        state = file.read() ?? CheckInState()
    }

    /// From a modifier, on every render: its key, bundle ID, the level its code asks for, and who's signed in.
    package func start(_ starter: Starter, key: String, level: TaoolAnalytics.Level, userID: String? = nil, bundleID: String?) {
        settings.key = key
        if let bundleID { settings.bundleID = bundleID }
        settings.levels[starter] = level
        settings.userIDs[starter] = Kit.userID(userID)
        applyUser()
        if settling == nil {
            let grace = sessionGrace
            settling = Task { [weak self] in
                try? await Task.sleep(for: grace)
                self?.settle()
            }
        }
    }

    /// TaoolPurchases, which adds its part to every report.
    package func attach(_ contributor: any CheckInContributor) {
        self.contributor = contributor
    }

    /// TaoolFlags, which adds its part to every report and takes the values in the answer.
    package func attach(flags listener: any FlagsCheckInListener) {
        flagsListener = listener
    }

    /// The products that give access now as TaoolPurchases has them, taool's grants included; nil in an app without it, or
    /// before it has read StoreKit this launch.
    package var accessProducts: Set<String>? { contributor?.accessProducts }

    /// The account's key, as the modifiers pass it.
    package var key: String { settings.key }

    /// The app's bundle ID, or the one the modifiers pass for it.
    package var bundleID: String? { settings.bundleID ?? Bundle.main.bundleIdentifier }

    /// The level the app's code asks for: the most private of the modifiers', `.automatic` where none sets one.
    private var codeLevel: TaoolAnalytics.Level { .mostPrivate(settings.levels.values) }

    /// The level a check-in sends (never `.automatic`): the code's, else the taool app's (standard until it has said).
    package var level: TaoolAnalytics.Level { codeLevel.level(remote: state.analytics) }

    /// Who's signed in: the user TaoolKit's modifiers are passed, nil for no one.
    package var userID: String? { state.userID }

    /// The user the app passes now, whichever modifiers it passes one to.
    private var appUserID: String? { settings.userIDs[.purchases] ?? settings.userIDs[.flags] ?? settings.userIDs[.analytics] }

    /// The user the app passes, applied at once, so the next render (another scene's too) finds nothing to do, and once
    /// the session grace has passed, checked in. Until then the app's first check-in carries them.
    private func applyUser() {
        let user = appUserID
        guard user != state.userID, settled || user != nil else { return }
        state.userID = user
        save()
        // Outside the view update `start` is called from.
        Task {
            contributor?.userChanged()
            flagsListener?.userChanged()
        }
        if settled, launched { checkInUser() }
    }

    /// The session grace has passed: a user the app no longer passes is signed out now, and one taool hasn't heard of is
    /// checked in.
    private func settle() {
        settled = true
        if appUserID != state.userID { applyUser() } else if launched { checkInUser() }
    }

    /// A check-in for who's signed in, in turn, unless taool has heard of them by then or a backoff holds it: StoreKit read
    /// again for them, and taool's answer applying at once.
    private func checkInUser() {
        let previous = checkInChain
        checkInChain = Task {
            _ = await previous?.value
            guard state.userID != state.reportedUserID, isDue(.user, at: .whenDue, now: .now) else { return true }
            await contributor?.prepare(now: .now, userChanged: true)
            return await sendCheckIns(.user, at: .whenDue, leaving: false, transition: true)
        }
    }

    /// A scene became active: the app is in use until it leaves. The first, as the app comes to the foreground, is when
    /// TaoolFlags' new values apply, never another window's or one back from Control Center, whose screens are in use.
    func becameActive(scene: UUID) async {
        // Neither waits on the other.
        let flagsRead = scenes.becameActive(scene) ? flagsListener.map { flags in Task { await flags.becameActive(now: .now) } } : nil
        await becameActive()
        await flagsRead?.value
    }

    /// A scene went to the background or closed: the app leaves with the last scene in use, never while another window
    /// is, nor for a scene that never became active (one made as the app launched in the background).
    func left(scene: UUID) async {
        guard scenes.left(scene) else { return }
        await wentToBackground()
    }

    /// The app became active: an open (expanded analytics), what TaoolPurchases reads, and a check-in when
    /// due. A call while one runs waits for it rather than doing it all again.
    package func becameActive(now: Date = .now) async {
        if let activating { return await activating.value }
        let task = Task { await activate(now: now) }
        activating = task
        await task.value
        activating = nil
    }

    private func activate(now: Date) async {
        if level == .expanded, now.timeIntervalSince(state.lastOpenedAt ?? .distantPast) >= Self.sameOpen,
           backgroundedAt.map({ now.timeIntervalSince($0) >= Self.sameOpen }) ?? true {
            state.opens += 1
            state.lastOpenedAt = now
            state.opened(on: now)
            save()
        }
        backgroundedAt = nil
        let urgency: CheckInUrgency = launched ? .whenDue : .coldLaunch
        launched = true
        let userChanged = state.userID != state.reportedUserID
        // StoreKit read again in full only for a check-in that goes.
        await contributor?.prepare(now: now, userChanged: userChanged && isDue(.user, at: urgency, now: now))
        await checkIn(userChanged ? .user : .launch, at: urgency, transition: true)
    }

    /// The app left, its last scene gone to the background or closed: a check-in when one is due, as when it comes back,
    /// so a long session checks in as it ends as well as as it starts, and "last seen" is when it ended. Run to its end in
    /// a task of its own, so the scene's task ending doesn't cancel it, and on iOS inside an expiring activity, which keeps
    /// the app running the few seconds the request needs before it's suspended. A call while one runs waits for it.
    package func wentToBackground(now: Date = .now) async {
        backgroundedAt = now
        if let leaving { return await leaving.value }
        // Nothing due, as most times: no task, and no time asked of the system.
        guard !settings.key.isEmpty, isDue(.launch, at: .whenDue, now: now) else { return }
        let task = Task { _ = await checkIn(.launch, leaving: true) }
        leaving = task
        #if !os(macOS)
        ProcessInfo.processInfo.performExpiringActivity(withReason: "TaoolKit check-in") { expired in
            guard !expired else { return }
            let done = DispatchSemaphore(value: 0)
            Task { await task.value; done.signal() }
            _ = done.wait(timeout: .now() + 25)
        }
        #endif
        await task.value
        leaving = nil
    }

    /// Checks in when due (`isDue`): which Apple Account this is, the device's facts at the app's level and TaoolPurchases'
    /// and TaoolFlags' parts, then taool's answer kept. One at a time, in order. `leaving`: sent as the app goes to the
    /// background, which the report says (`flush`); `transition`, or leaving: as the app becomes active or leaves, when
    /// TaoolFlags may show new values. True when taool answered (or nothing was due and nothing's queued).
    @discardableResult
    package func checkIn(_ reason: CheckInReason, at urgency: CheckInUrgency = .whenDue, leaving: Bool = false, transition: Bool = false) async -> Bool {
        let previous = checkInChain
        let task = Task<Bool, Never> {
            _ = await previous?.value
            return await sendCheckIns(reason, at: urgency, leaving: leaving, transition: transition || leaving)
        }
        checkInChain = task
        return await task.value
    }

    /// Sends check-ins until TaoolPurchases' queue is empty (a long restore takes several) or one fails.
    private func sendCheckIns(_ reason: CheckInReason, at urgency: CheckInUrgency, leaving: Bool, transition: Bool) async -> Bool {
        var (reason, urgency, leaving, transition) = (reason, urgency, leaving, transition)
        while true {
            let sent = await sendCheckIn(reason, at: urgency, leaving: leaving, transition: transition)
            guard sent == .answered, let pending = contributor?.pendingReason else { return sent != .failed }
            // What's left of the queue goes at once, under the reason it was queued with, no longer the transition's.
            (reason, urgency, leaving, transition) = (pending, .whenDue, false, false)
        }
    }

    /// Whether a check-in for `reason` at `urgency` goes now: the most urgent of the two and what's queued (`atOnce`).
    private func isDue(_ reason: CheckInReason, at urgency: CheckInUrgency, now: Date) -> Bool {
        let queued: CheckInUrgency = contributor?.pendingReason != nil ? .atOnce : .whenDue
        return CheckInSchedule.isDue(state, urgency: max(urgency, reason.urgency, queued), now: now)
    }

    private enum Sent { case answered, nothingDue, failed }

    private func sendCheckIn(_ reason: CheckInReason, at urgency: CheckInUrgency, leaving: Bool, transition: Bool, now: Date = .now) async -> Sent {
        // Nothing goes without a key: not an answer from taool.
        guard !settings.key.isEmpty else {
            Notice.once("No taool key, so TaoolKit doesn't check in. The key is on the taool app's TaoolKit page.", log: log)
            return .failed
        }
        guard let bundleID else { return .failed }
        ServerKeyGuard.check(settings.key, log: log)
        guard isDue(reason, at: urgency, now: now) else { return .nothingDue }
        let (contributor, flagsListener, userID) = (contributor, flagsListener, state.userID)
        let pendingReason = contributor?.pendingReason
        let next = contributor?.nextPart()
        let flags = flagsListener.map { _ in CheckInReport.Flags() }
        let (level, opens, lastOpenedAt, openedDays, readAppTransaction) = (level, state.opens, state.lastOpenedAt, state.openedDays, appTransaction)
        // Neither waits on the other: both ask StoreKit.
        async let currentRead = readAppTransaction()
        async let device = DeviceFacts.collect(level, opens: opens, lastOpenedAt: lastOpenedAt, openedDays: openedDays)
        let current = await currentRead
        // The other build's, kept from before it was installed over: once, as the environment changed.
        var previous: String?
        if let kept = state.keptAppTransaction, let current, kept.isTestBuild != current.isTestBuild { previous = kept.signed }
        let report = CheckInReport(
            reason: max(reason, pendingReason ?? reason), appTransaction: current?.signed, userId: userID, level: codeLevel.number,
            device: await device, purchases: next?.part, flush: leaving ? true : nil, flags: flags, previousAppTransaction: previous)

        switch await client.send(report, key: settings.key, bundleID: bundleID) {
        case .answered(let answer):
            checkedIn(at: now, userID: userID, carrying: current)
            state.syncInterval = answer.syncInterval
            state.launchInterval = answer.launchInterval
            state.analytics = answer.analytics
            state.failures = 0
            state.backoffUntil = nil
            if report.device?.opens != nil { state.opens = max(state.opens - opens, 0) }
            if let sent = report.device?.openedDays { state.openedDays.removeAll { sent.contains($0) } }
            // Expanded analytics switched off: nothing more is counted, and what was is dropped.
            if self.level != .expanded { state.opens = 0; state.lastOpenedAt = nil; state.openedDays = [] }
            save()
            // What went is never sent again, whether taool took it or the app isn't connected yet. What's another user's is
            // about the user it carried, so it's left out once another has signed in.
            let otherUser = userID == state.userID ? answer.otherUser : nil
            if let next { contributor?.checkedIn(.answered(otherUser: otherUser, grants: answer.grants), sent: next.sent) }
            flagsListener?.checkedIn(flags: answer.flags, userFlags: answer.userFlags, interval: answer.flagsInterval,
                                     userID: userID, transition: transition)
            return .answered
        case .refused:
            log.error("taool refused a check-in as invalid, so it's dropped.")
            checkedIn(at: now, userID: userID, carrying: current)
            save()
            if let next { contributor?.checkedIn(.refused, sent: next.sent) }
            return .answered
        case .unknownApp:
            Notice.once("taool doesn't know \(bundleID) for this key. Is it one of your apps in taool, and is the key right?", log: log)
            state.backoffUntil = now.addingTimeInterval(CheckInSchedule.daily)
            save()
            return .failed
        case .failed:
            state.failures += 1
            state.backoffUntil = now.addingTimeInterval(CheckInSchedule.retryDelay(failures: state.failures))
            save()
            log.info("Couldn't reach taool to check in; will try again.")
            return .failed
        }
    }

    /// A check-in taool answered or refused: either way, what it carried counts as told, or every launch would send it
    /// again.
    private func checkedIn(at now: Date, userID: String?, carrying current: AppTransactionFacts?) {
        state.lastCheckIn = now
        state.reportedUserID = userID
        if let current { state.keptAppTransaction = KeptAppTransaction(signed: current.signed, isTestBuild: current.isTestBuild) }
    }

    private func save() {
        file.write(state)
    }
}
