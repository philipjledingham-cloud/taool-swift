// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import TaoolCore

/// What the check-in keeps on the device between launches: taool's last answer (what to collect, when to check in), the
/// backoff after a failure, who's signed in, and the opens counted for expanded analytics.
struct CheckInState: FileState, Equatable {
    var lastCheckIn: Date?
    var syncInterval: Int?
    var launchInterval: Int?
    var analytics: String?
    var backoffUntil: Date?
    var failures = 0

    /// Who's signed in, as the app last passed them (`CheckIns.userID`), so the launch starts with them.
    var userID: String?
    /// The user the last check-in taool answered carried: until it's `userID`, a check-in carries them at once.
    var reportedUserID: String?

    /// Expanded analytics: opens since the last check-in taool answered, and the latest.
    var opens = 0
    var lastOpenedAt: Date?
    /// Expanded analytics: the UTC days ("2026-10-11") the app was opened on since the last check-in taool
    /// answered, the newest last, for daily users.
    var openedDays: [String] = []
    /// The days kept at most: a device offline for months sends its last ones.
    static let maxOpenedDays = 64

    /// The AppTransaction the last answered check-in sent, kept so the other build installed over this one (the App Store's
    /// over TestFlight's, or the other way) sends it once, and taool knows the two are one Apple Account. Lost with the
    /// app, as everything here is.
    var keptAppTransaction: KeptAppTransaction?

    /// Marks `now`'s UTC day as one the app was opened on.
    mutating func opened(on now: Date) {
        let day = now.formatted(.iso8601.year().month().day())
        guard !openedDays.contains(day) else { return }
        openedDays = Array((openedDays + [day]).suffix(Self.maxOpenedDays))
    }
}

/// The AppTransaction as the check-in's file keeps it: its own type, so a field `AppTransactionFacts` gains later never
/// stops an older file from being read (which would lose the whole state).
struct KeptAppTransaction: Codable, Sendable, Equatable {
    let signed: String
    let isTestBuild: Bool
}

extension StateFile where State == CheckInState {
    static var standard: StateFile { inAppSupport("check-in.json") }
}

/// How soon a check-in goes, least urgent first; it goes at the most urgent of what asks for it.
package enum CheckInUrgency: Int, Comparable, Sendable {
    /// Once taool's interval has passed, as the app comes back or leaves.
    case whenDue
    /// The first time the app becomes active in a launch, once taool's launch wait has passed (none unless it says), so a
    /// grant shows once the app is restarted.
    case coldLaunch
    /// A new user, or something queued, but not while a failed check-in's backoff lasts, so a key or app taool doesn't
    /// know, or taool out of reach, never sends one at every open.
    case atOnce
    /// Whatever the backoff: a purchase or restore, or the app asking (`TaoolPurchases.refresh()`).
    case now

    package static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// When a check-in is due: never on every open.
enum CheckInSchedule {
    /// The interval taool's answer gives is kept between these; a check-in only ever goes as the app opens or leaves, never
    /// on a timer.
    static let shortest: TimeInterval = 60
    static let longest: TimeInterval = 7 * 24 * 60 * 60
    /// Before any answer: every 6 hours as the app comes back.
    static let fallback: TimeInterval = 6 * 60 * 60
    /// An app taool doesn't know waits a day.
    static let daily: TimeInterval = 24 * 60 * 60
    /// A failed check-in waits this long, doubling to an hour.
    static let firstRetry: TimeInterval = 60
    static let longestRetry: TimeInterval = 60 * 60

    static func interval(answered: Int?) -> TimeInterval {
        min(max(answered.map(TimeInterval.init) ?? fallback, shortest), longest)
    }

    /// How long a cold launch waits after the last check-in: not at all unless taool's answer says, and never longer than
    /// the interval.
    static func launchWait(answered: Int?, interval: TimeInterval) -> TimeInterval {
        min(max(answered.map(TimeInterval.init) ?? 0, 0), interval)
    }

    /// Whether a check-in of `urgency` goes now, by what `state` kept: taool's interval and launch wait, the last check-in
    /// and a failed one's backoff, which only `now` goes through. A time kept further ahead than any could be (the
    /// device's clock was set back) holds nothing.
    static func isDue(_ state: CheckInState, urgency: CheckInUrgency, now: Date) -> Bool {
        if urgency < .now, let until = state.backoffUntil, until > now, until.timeIntervalSince(now) <= daily { return false }
        if urgency >= .atOnce { return true }
        guard let last = state.lastCheckIn, last <= now else { return true }
        let interval = interval(answered: state.syncInterval)
        let wait = urgency == .coldLaunch ? launchWait(answered: state.launchInterval, interval: interval) : interval
        return now.timeIntervalSince(last) >= wait
    }

    static func retryDelay(failures: Int) -> TimeInterval {
        min(firstRetry * pow(2, Double(max(failures - 1, 0))), longestRetry)
    }
}
