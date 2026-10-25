// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import StoreKit
import TaoolAnalytics

extension TaoolPurchases {
    /// Something that gives access now: a subscription, a purchase that unlocks something for good
    /// (lifetime, or an item such as a city guide), or a grant from the developer in taool (beta
    /// testers, support). Named as StoreKit 2 names the same things (`Transaction`, its `Offer`, the
    /// renewal info and status), with StoreKit's own types.
    public struct Entitlement: Sendable, Hashable, Identifiable, Codable {
        /// The offer that set the current period's price, as `Transaction.Offer` has it.
        public struct Offer: Sendable, Hashable, Codable {
            // StoreKit's types aren't Codable, so they're kept as their raw values.
            private let typeRawValue: Int
            private let paymentModeRawValue: String?
            public let id: String?

            public var type: Transaction.OfferType { .init(rawValue: typeRawValue) }
            public var paymentMode: Product.SubscriptionOffer.PaymentMode? {
                paymentModeRawValue.map(Product.SubscriptionOffer.PaymentMode.init(rawValue:))
            }

            init(type: Transaction.OfferType, paymentMode: Product.SubscriptionOffer.PaymentMode?, id: String?) {
                (typeRawValue, paymentModeRawValue, self.id) = (type.rawValue, paymentMode?.rawValue, id)
            }
        }

        /// The product: the subscription bought, the item, or the product a grant unlocks.
        public let productID: String
        /// When it was bought: this period's purchase, for a subscription. Nil for a grant.
        public let purchaseDate: Date?
        /// When it was first bought: a subscription's first period. Nil for a grant.
        public let originalPurchaseDate: Date?
        /// When access ends: the period's end, or a grant's. Nil for a purchase that's for good, or a
        /// grant without an end.
        public let expirationDate: Date?
        /// The offer behind the current period's price; nil for the normal price.
        public let offer: Offer?
        /// The subscription group, for a subscription.
        public let subscriptionGroupID: String?
        /// StoreKit's original transaction ID (`Transaction.originalID`), the same across renewals; nil for a grant.
        public let originalTransactionID: UInt64?
        /// Given by the developer in taool rather than bought.
        public let isGrant: Bool
        /// It renews at `expirationDate`.
        public internal(set) var willAutoRenew: Bool

        private let ownershipTypeRawValue: String
        private let environmentRawValue: String
        private var stateRawValue: Int?

        /// Bought on this Apple Account (`.purchased`, a grant's too), or shared by a family member (`.familyShared`).
        public var ownershipType: Transaction.OwnershipType { .init(rawValue: ownershipTypeRawValue) }
        /// Where it was bought: the App Store, the sandbox (TestFlight, development builds) or Xcode.
        public var environment: AppStore.Environment { .init(rawValue: environmentRawValue) }
        /// A subscription's state: `.subscribed`, or `.inGracePeriod` while Apple retries a failed renewal
        /// with access kept, a good moment to ask the user to update their payment details. Nil for
        /// anything else.
        public internal(set) var state: Product.SubscriptionInfo.RenewalState? {
            get { stateRawValue.map(Product.SubscriptionInfo.RenewalState.init(rawValue:)) }
            set { stateRawValue = newValue?.rawValue }
        }

        /// In a free trial.
        public var isTrial: Bool { offer?.paymentMode == .freeTrial }

        /// Its subscription or purchase and its product, so a subscription's new plan and the one it replaces, both
        /// listed until a downgrade's renewal, are told apart.
        public var id: String { "\(originalTransactionID.map(String.init) ?? "grant"):\(productID)" }

        init(productID: String, purchaseDate: Date?, originalPurchaseDate: Date?, expirationDate: Date?, offer: Offer?,
             subscriptionGroupID: String?, originalTransactionID: UInt64?, isGrant: Bool = false, willAutoRenew: Bool = false,
             ownershipType: Transaction.OwnershipType = .purchased, environment: AppStore.Environment = .production,
             state: Product.SubscriptionInfo.RenewalState? = nil) {
            (self.productID, self.purchaseDate, self.originalPurchaseDate, self.expirationDate, self.offer) =
                (productID, purchaseDate, originalPurchaseDate, expirationDate, offer)
            (self.subscriptionGroupID, self.originalTransactionID, self.isGrant, self.willAutoRenew) = (subscriptionGroupID, originalTransactionID, isGrant, willAutoRenew)
            (ownershipTypeRawValue, environmentRawValue, stateRawValue) = (ownershipType.rawValue, environment.rawValue, state?.rawValue)
        }
    }
}

enum Entitlements {
    /// What gives access now: StoreKit's, less those taool says are another of the app's users'
    /// (only while a user is signed in, since then a restore elsewhere moved it), plus taool's grants
    /// still running, one per product, the one lasting longest. A grant for a product StoreKit already has
    /// adds nothing. The one that lasts longest first.
    static func merge(storeKit: [TaoolPurchases.Entitlement], otherUser: Set<String>, grants: [Grant], signedIn: Bool,
                      now: Date) -> [TaoolPurchases.Entitlement] {
        var result = storeKit.filter { entitlement in
            if signedIn, let original = entitlement.originalTransactionID, otherUser.contains(String(original)) { return false }
            // A cached copy whose period ended, unless Apple's grace period still gives access.
            if let end = entitlement.expirationDate, end <= now, entitlement.state != .inGracePeriod { return false }
            return true
        }
        let owned = Set(result.map(\.productID))
        let running = grants.filter { !owned.contains($0.productId) && ($0.expirationDate.map { $0 > now } ?? true) }
        let longest = Dictionary(running.map { ($0.productId, $0) }) { ($0.expirationDate ?? .distantFuture) >= ($1.expirationDate ?? .distantFuture) ? $0 : $1 }
        for grant in longest.values {
            result.append(.init(productID: grant.productId, purchaseDate: nil, originalPurchaseDate: nil, expirationDate: grant.expirationDate,
                                offer: nil, subscriptionGroupID: nil, originalTransactionID: nil, isGrant: true))
        }
        return result.sorted { ($0.expirationDate ?? .distantFuture) > ($1.expirationDate ?? .distantFuture) }
    }

    /// StoreKit has this Apple Account's subscription, but it's another of the app's users' (taool
    /// says so): the app can say why there's no access, and offer Restore.
    static func isOnAnotherAccount(storeKit: [TaoolPurchases.Entitlement], otherUser: Set<String>, signedIn: Bool) -> Bool {
        signedIn && storeKit.contains { $0.originalTransactionID.map { otherUser.contains(String($0)) } ?? false }
    }
}
