// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import CryptoKit
import Foundation

/// SHA-256 as TaoolKit uses it: where a user lands in a split, and a user ID that never leaves the device as it is.
package enum Hash {
    /// The same text always lands in the same bucket, on every device and on a server working it out alike: the first 8
    /// bytes of its SHA-256, read big-endian, modulo `count`.
    package static func bucket(_ text: String, count: Int) -> Int {
        let value = SHA256.hash(data: Data(text.utf8)).prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Int(value % UInt64(count))
    }

    /// In lowercase hex.
    package static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    /// In lowercase hex.
    package static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
