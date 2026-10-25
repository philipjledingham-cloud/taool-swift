// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation

/// App Store version numbers, compared number by number: "1.10" is after "1.9", and "1.8" is "1.8.0".
package enum Versions {
    package static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (left, right) = (parts(a), parts(b))
        for index in 0..<max(left.count, right.count) {
            let (l, r) = (index < left.count ? left[index] : 0, index < right.count ? right[index] : 0)
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    package static func isNewer(_ a: String, than b: String) -> Bool { compare(a, b) == .orderedDescending }

    package static func isSame(_ a: String, _ b: String) -> Bool { compare(a, b) == .orderedSame }

    /// A part without leading digits counts as 0.
    private static func parts(_ version: String) -> [Int] {
        version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
