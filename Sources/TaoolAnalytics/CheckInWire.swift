// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import TaoolCore

/// Why a check-in is sent, weakest first: a restore or purchase moves a subscription to the user
/// signed in (with accounts), a user change sends what the device has again, and a launch or update
/// only reports what's new. A check-in sends the strongest reason of what it carries.
package enum CheckInReason: String, Codable, Sendable, Comparable {
    case launch, update, user, purchase, restore

    private var strength: Int {
        switch self {
        case .launch: 0
        case .update: 1
        case .user: 2
        case .purchase: 3
        case .restore: 4
        }
    }

    package static func < (lhs: Self, rhs: Self) -> Bool { lhs.strength < rhs.strength }

    /// How soon it goes: a purchase or restore, which the user is waiting on, whatever a failed check-in's backoff says.
    var urgency: CheckInUrgency {
        switch self {
        case .launch, .update: .whenDue
        case .user: .atOnce
        case .purchase, .restore: .now
        }
    }
}

/// One check-in: which Apple Account this is (StoreKit's signed AppTransaction), who's signed in, what the device says
/// about itself at the app's analytics level, and TaoolPurchases' and TaoolFlags' parts: what StoreKit signed that taool
/// hasn't seen.
package struct CheckInReport: Encodable, Sendable, Equatable {
    /// TaoolPurchases' part, sent whenever it's in the app, even with nothing in it.
    package struct Purchases: Encodable, Sendable, Equatable {
        package let transactions: [String]?
        package let renewals: [String]?
        /// The IDs of the transactions a purchase or Restore Purchases queued, which move to the user signed in: never one
        /// that only went in the same check-in.
        package let moving: [String]?

        package init(transactions: [String]?, renewals: [String]?, moving: [String]? = nil) {
            (self.transactions, self.renewals, self.moving) = (transactions, renewals, moving)
        }
    }

    /// TaoolFlags' part, sent (empty) whenever it's in the app, so taool answers with the values picked for this user.
    package struct Flags: Encodable, Sendable, Equatable {}

    let reason: CheckInReason
    // Minimal: every check-in. Which Apple Account this is, as StoreKit signed it; nothing about the device.
    let appTransaction: String?
    /// Who's signed in, the app's own user ID as it passed it to any of TaoolKit's modifiers, at every level.
    var userId: String? = nil
    /// The level the app's code set (`TaoolAnalytics.Level.number`), at every level, so the taool app says what it sends.
    var level = 0
    // Standard and expanded only (`DeviceFacts`, its fields headed by level); nil at minimal.
    let device: DeviceFacts?
    // With TaoolPurchases, at every level: what access needs.
    let purchases: Purchases?
    /// True for a check-in sent as the app goes to the background; else left out.
    var flush: Bool? = nil
    // With TaoolFlags.
    var flags: Flags? = nil
    /// The AppTransaction kept from the other build this device ran (TestFlight's before the App Store's, or the other
    /// way), sent once as it changes, so taool knows the two are one Apple Account; Apple signed it, as it did the other.
    var previousAppTransaction: String? = nil
}

/// What taool answered. An empty list means none, and the device drops what it had; a list left out means taool didn't
/// look (the app isn't connected to Subscriptions, or the check-in didn't prove its Apple Account), and the device keeps
/// what it had, so a check-in that proves nothing never takes access away.
struct CheckInAnswer: Decodable, Sendable, Equatable {
    /// "expanded" turns expanded analytics on; anything else is standard.
    let analytics: String?
    /// Seconds until a check-in is due again, as the app comes back or leaves.
    let syncInterval: Int?
    /// Seconds a cold launch waits after the last check-in; without it, every cold launch checks in.
    let launchInterval: Int?
    /// TaoolPurchases: this Apple Account's subscriptions that are another of the app's users'.
    let otherUser: [String]?
    /// TaoolPurchases: this Apple Account's grants.
    let grants: [Grant]?
    /// TaoolFlags: the values the developer picked for this Apple Account, once it's proven.
    var flags: [FlagOverride]? = nil
    /// TaoolFlags: the values picked for the user ID sent, proven or not.
    var userFlags: [FlagOverride]? = nil
    /// TaoolFlags: seconds until the flags are asked for again, as the app becomes active.
    var flagsInterval: Int? = nil
}

/// A flag's value the developer picked for this user, as taool's answer names it.
package struct FlagOverride: Codable, Sendable, Hashable {
    package let key: String
    package let value: JSONValue

    package init(key: String, value: JSONValue) {
        (self.key, self.value) = (key, value)
    }
}

/// A JSON value as taool sends it: a flag's value is one (true or false for a flag that's on or off).
package enum JSONValue: Codable, Sendable, Hashable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// A grant to this Apple Account, as taool's answer names it.
package struct Grant: Codable, Sendable, Hashable {
    package let productId: String
    package let expirationDate: Date?

    package init(productId: String, expirationDate: Date?) {
        (self.productId, self.expirationDate) = (productId, expirationDate)
    }
}

/// Sends check-ins. Nothing here throws: a failure is an outcome, and what wasn't sent stays queued.
package struct CheckInClient: Sendable {
    enum Outcome: Sendable, Equatable {
        case answered(CheckInAnswer)
        /// taool refused the report as malformed (400): sending it again won't help.
        case refused
        /// The key and bundle ID aren't an account's app (404).
        case unknownApp
        /// Offline, or taool didn't answer: try again later.
        case failed
    }

    var session = Kit.session
    var baseURL = Kit.baseURL

    func send(_ report: CheckInReport, key: String, bundleID: String) async -> Outcome {
        var url = baseURL.appending(path: "v1/sync/\(bundleID)")
        url.append(queryItems: [URLQueryItem(name: "key", value: key)])
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try Kit.encoder.encode(report)
            let (data, response) = try await session.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                return (try? Kit.decoder.decode(CheckInAnswer.self, from: data)).map(Outcome.answered) ?? .failed
            case 400:
                return .refused
            case 404:
                return .unknownApp
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }
}
