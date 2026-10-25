// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation

/// When an answer kept on the device is asked for again: once a launch unless it was asked in the last five minutes, then
/// at most hourly. A failure waits five minutes too.
package enum RefreshSchedule {
    static let launch: TimeInterval = 5 * 60
    static let hourly: TimeInterval = 60 * 60

    /// `askedAt`: when it was last asked this launch, whatever came of it; `fetchedAt`: when the answer kept came, which
    /// is due when it's later than now (the device's clock was set back).
    package static func isDue(askedAt: Date?, fetchedAt: Date?, now: Date) -> Bool {
        if let askedAt, now.timeIntervalSince(askedAt) < launch { return false }
        guard let fetchedAt, fetchedAt <= now else { return true }
        return now.timeIntervalSince(fetchedAt) >= (askedAt == nil ? launch : hourly)
    }
}
