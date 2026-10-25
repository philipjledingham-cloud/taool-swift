// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import TaoolAnalytics
import TaoolCore

/// What TaoolPurchases keeps on the device between launches: the signed items queued for taool and the
/// ones it has (so nothing is sent twice), what taool last said about this Apple Account (grants, and
/// subscriptions that are another user's), and the last entitlements StoreKit gave (so `hasAccess` is
/// right the moment the app starts). When to check in and the analytics are the check-in's own
/// (TaoolAnalytics).
struct PurchasesState: FileState, Equatable {
    /// A signed transaction ("t…") or renewal info ("r…") waiting for a check-in, by what it says
    /// (`TaoolPurchases.pending`).
    struct Pending: Codable, Sendable, Equatable {
        let key: String
        let jws: String
        /// Queued by a purchase or Restore Purchases, so it moves to the user signed in; nil for the rest.
        var moves: Bool?

        var isRenewal: Bool { key.hasPrefix("r") }

        /// The transaction's ID, from its key ("t2000000123.8f…").
        var transactionID: String { String(key.dropFirst().prefix { $0 != "." }) }
    }

    /// Items the queue keeps at most: a restore of a long history is sent across several check-ins,
    /// and a device offline for months doesn't grow without end.
    static let maxPending = 200
    /// Sent items remembered, so a launch doesn't send them again; the oldest are forgotten first.
    static let maxSent = 400

    var pending: [Pending] = []
    /// The strongest reason among what's queued: a restore stays a restore however long it waits.
    var pendingReason: CheckInReason?
    /// Keys taool has, the latest last.
    var sent: [String] = []

    var otherUser: [String] = []
    /// Who `otherUser` was answered for: it's theirs alone, so another user signed in has StoreKit's answer until taool's.
    var otherUserOf: String?
    var grants: [Grant] = []

    var cachedEntitlements: [TaoolPurchases.Entitlement] = []

    /// Queues a signed item unless taool has it or it's queued; `again` queues it whatever taool has
    /// (a restore, a new user). A purchase or restore marks it to move to the user signed in, one already
    /// queued too, and its reason counts either way. True when it was queued.
    @discardableResult
    mutating func queue(_ item: Pending, reason: CheckInReason, again: Bool = false) -> Bool {
        let moves = reason == .purchase || reason == .restore
        if let index = pending.firstIndex(where: { $0.key == item.key }) {
            if moves { pending[index].moves = true }
            pendingReason = max(pendingReason ?? reason, reason)
            return false
        }
        guard again || !sent.contains(item.key) else { return false }
        var item = item
        if moves { item.moves = true }
        pending = Array((pending + [item]).suffix(Self.maxPending))
        pendingReason = max(pendingReason ?? reason, reason)
        return true
    }

    /// What taool now has: out of the queue, and remembered.
    mutating func markSent(_ keys: [String]) {
        let done = Set(keys)
        pending.removeAll { done.contains($0.key) }
        sent = Array((sent.filter { !done.contains($0) } + keys).suffix(Self.maxSent))
        if pending.isEmpty { pendingReason = nil }
    }
}

extension StateFile where State == PurchasesState {
    static var standard: StateFile { inAppSupport("purchases.json") }
}
