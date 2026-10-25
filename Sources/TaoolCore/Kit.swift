// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation

/// How TaoolKit talks to taool: kit.taool.com, in a session of its own, with dates as "2026-10-15T08:00:00Z" both ways.
package enum Kit {
    /// TaoolKit's own version, which a release's tag must be (`scripts/release.sh`).
    package static let version = "1.0.0"

    package static let baseURL = URL(string: "https://kit.taool.com")!

    /// Keeps no cache or cookies: what TaoolKit keeps, it keeps itself, never in the app's own.
    package static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    package static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    package static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The app's user ID as TaoolKit takes it: trimmed, and an empty one is none, as is one longer than taool takes.
    package static func userID(_ id: String?) -> String? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        guard id.utf16.count <= 128 else {
            assertionFailure("A user ID is at most 128 characters, so TaoolKit takes this one as no one signed in.")
            return nil
        }
        return id
    }

    /// A user ID that's a UUID, with its dashes or without, as taool's server reads it too.
    package static func uuid(_ id: String) -> UUID? {
        var hex = id
        if hex.count == 32, !hex.contains("-") {
            for offset in [8, 13, 18, 23] { hex.insert("-", at: hex.index(hex.startIndex, offsetBy: offset)) }
        }
        return UUID(uuidString: hex)
    }
}
