// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import os

/// TaoolKit's notices for the developer, each said once a launch: what's wrong (no key, an app taool doesn't know, a name it
/// can't count) comes up at every scene becoming active, request or read, and would fill the console.
package enum Notice {
    private static let said = OSAllocatedUnfairLock(initialState: Set<String>())
    /// The notices kept at most: past them, one is said each time, so names an app makes up can't grow the set for good.
    private static let kept = 100

    package static func once(_ message: String, log: Logger, level: OSLogType = .default) {
        guard said.withLock({ $0.count >= kept || $0.insert(message).inserted }) else { return }
        log.log(level: level, "\(message, privacy: .public)")
    }
}
