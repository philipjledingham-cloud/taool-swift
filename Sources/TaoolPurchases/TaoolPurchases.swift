// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import os
import StoreKit
import SwiftUI
@_exported import TaoolAnalytics
import TaoolCore

/// In-app purchases with taool: who has access, worked out on the device from StoreKit the moment
/// the app starts, and kept right by taool (grants you give, a subscription that moved to another of
/// your users). Subscriptions, lifetime unlocks and other non-consumables alike, but for non-renewing
/// subscriptions, whose length is the app's own to decide. Your own StoreKit code buys; TaoolKit only
/// watches, so nothing waits on taool.
///
/// ```swift
/// ContentView()
///     .taoolPurchases(key: "taool_public_…", userID: session.user?.id.uuidString)   // each scene's root view
///
/// @Environment(TaoolPurchases.self) private var purchases
/// if purchases.hasAccess { … }                                     // anything: an app that sells one thing
/// if purchases.has("guide.paris") { … }                            // one product, or any of several
/// purchases.currentEntitlement(for: "pro.yearly")?.expirationDate  // its details, named as StoreKit names them
///
/// let result = try await product.purchase(options: purchases.purchaseOptions)
/// purchases.record(result)                               // every purchase your code makes: access has it at once
/// try await purchases.restore()                          // your Restore Purchases button
/// await purchases.refresh()                              // optional: a Check Access button, never asks to sign in
/// ```
///
/// TaoolKit never calls `purchase`, never finishes a transaction (your code does, as it does now), and
/// never blocks: when taool can't be reached, StoreKit's answer stands. Where StoreKit 2 has a name for
/// something, TaoolKit uses it. It checks in through TaoolAnalytics' one check-in, adding its part, so
/// the app's users are counted too, with no `.taoolAnalytics` needed.
@MainActor
@Observable
public final class TaoolPurchases {
    /// The one TaoolKit uses, for code outside SwiftUI views (and the same one the environment has).
    public static let shared = TaoolPurchases()

    /// What gives access now, the one that lasts longest first: subscriptions and purchases StoreKit
    /// has for this Apple Account, and grants from taool. Right from launch: the last copy is kept on
    /// the device until StoreKit answers, a moment later.
    public private(set) var currentEntitlements: [Entitlement] = []

    /// Something gives access: a subscription, a purchase or a grant. For an app that sells one thing;
    /// one that sells several asks about each with `has(_:)`.
    public var hasAccess: Bool { !currentEntitlements.isEmpty }

    /// One of these products gives access: a subscription to it, a purchase of it (lifetime, or an item
    /// such as a city guide), or a grant of it.
    public func has(_ productIDs: String...) -> Bool {
        currentEntitlements.contains { productIDs.contains($0.productID) }
    }

    /// The longest-lasting entitlement among these products, for its details (when it ends, whether
    /// it renews, a trial); nil when none of them gives access.
    public func currentEntitlement(for productIDs: String...) -> Entitlement? {
        currentEntitlements.first { productIDs.contains($0.productID) }
    }

    /// With your users signed in: this Apple Account has a subscription, but another of your users
    /// restored or bought it, so it isn't this user's. Say so, and offer Restore Purchases, which
    /// moves it here.
    public private(set) var isOnAnotherAccount = false

    /// StoreKit has answered since launch. Before that, `currentEntitlements` are the last copy kept on the device.
    public private(set) var isLoaded = false

    /// Options for your own purchase call, so Apple's transaction names the user signed in: their ID
    /// as the App Account Token when it's a UUID. StoreKit's views below the modifier get them already.
    public var purchaseOptions: Set<Product.PurchaseOption> {
        guard let userID = checkIns.userID, let uuid = Kit.uuid(userID) else { return [] }
        return [.appAccountToken(uuid)]
    }

    /// For every purchase your own code makes, which StoreKit hands only to your code: access has it from this call on
    /// (without it, a lifetime unlock or an item gives access only as the app next comes to the foreground), and taool
    /// hears of it right after, as a purchase, which with your users signed in moves a subscription this Apple Account
    /// already had to the user buying. The task it returns is for code that needs taool to have the purchase first:
    /// true once it has, false when taool can't be reached, or for a result that isn't a verified purchase
    /// (cancelled, pending). StoreKit's views tell TaoolKit themselves, unless your `onInAppPurchaseCompletion` takes
    /// their purchases: call it there.
    @discardableResult
    public func record(_ result: Product.PurchaseResult) -> Task<Bool, Never> {
        guard case .success(let verification) = result, case .verified(let transaction) = verification else { return Task { false } }
        state.queue(Self.pending(verification), reason: .purchase, again: true)
        // What StoreKit's entitlements will list, at once rather than once they're read a moment later, which replaces
        // it: a subscription just bought renews, and what else gives access stays until then (a downgrade waits for
        // the renewal, the plan it replaces still the user's).
        if var entitlement = Self.entitlement(transaction) {
            if transaction.productType == .autoRenewable { (entitlement.willAutoRenew, entitlement.state) = (true, .subscribed) }
            state.cachedEntitlements.removeAll { $0.id == entitlement.id }
            state.cachedEntitlements.append(entitlement)
            // A purchase moves it to the user buying, so it's no longer another user's.
            state.otherUser.removeAll { $0 == String(transaction.originalID) }
            recompute()
        }
        save()
        return Task {
            await reread(sendAgain: false, reason: .update)
            return await checkIns.checkIn(.purchase)
        }
    }

    /// For your Restore Purchases button: the App Store syncs this Apple Account's purchases, then
    /// taool hears of them, which with your users signed in moves its subscriptions to the user
    /// restoring. Throws what `AppStore.sync()` throws (the user cancelled signing in, say).
    public func restore() async throws {
        try await AppStore.sync()
        await reread(sendAgain: true, reason: .restore)
        await checkIns.checkIn(.restore)
    }

    /// Asks taool now what it has for this Apple Account (grants you give in taool, a subscription another of your
    /// users has), with StoreKit read again, but never the App Store's sync, so nothing asks the user to sign in:
    /// for a Check Access button, or a user you just gave access to. The app's next cold launch does the same on its
    /// own. False when taool couldn't be reached, and access stays as it was.
    @discardableResult
    public func refresh() async -> Bool {
        // A call while one is on its way waits for that one rather than sending another.
        if let refreshing { return await refreshing.value }
        let task = Task {
            await reread(sendAgain: false, reason: .launch)
            return await checkIns.checkIn(.launch, at: .now)
        }
        refreshing = task
        defer { refreshing = nil }
        return await task.value
    }

    @ObservationIgnored private var state: PurchasesState
    private let file: StateFile<PurchasesState>
    /// The one check-in, TaoolAnalytics', which this adds its part to, and whose user is who's signed in.
    let checkIns: CheckIns
    private let log = Logger(subsystem: "TaoolKit", category: "purchases")
    @ObservationIgnored private var started = false
    /// When StoreKit was last read, so a window or a glance at Control Center becoming active doesn't read it again.
    @ObservationIgnored private var readAt: Date?
    /// The state as last written, so an unchanged one isn't written again.
    @ObservationIgnored private var saved: PurchasesState
    @ObservationIgnored private var rereadChain: Task<Void, Never>?
    /// A `refresh()` on its way, which another call waits for.
    @ObservationIgnored private var refreshing: Task<Bool, Never>?
    @ObservationIgnored private var updateSoon: Task<Void, Never>?

    init(file: StateFile<PurchasesState> = .standard, checkIns: CheckIns = .shared) {
        self.file = file
        self.checkIns = checkIns
        state = file.read() ?? PurchasesState()
        saved = state
        recompute()
        checkIns.attach(self)
    }

    /// From the modifier, on every render, as the code has them now: all of it goes to the check-in, which
    /// checks a new user in. The first starts TaoolKit.
    func configure(key: String, userID: String?, analytics: TaoolAnalytics.Level = .automatic, bundleID: String? = nil) {
        checkIns.start(.purchases, key: key, level: analytics, userID: userID, bundleID: bundleID)
        guard !started else { return }
        started = true
        listen()
        // What views read is worked out in a task, never while the view that called this is being drawn.
        Task { recompute() }
    }

    /// StoreKit's own news: a renewal, a refund, another device's purchase, Ask to Buy approved, a
    /// subscription's status changing (a purchase in the app, from your code or StoreKit's views).
    private func listen() {
        Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                // One taool has, or that's queued already, is no news: StoreKit sends the unfinished at each launch.
                guard let self, case .verified = result, state.queue(Self.pending(result), reason: .update) else { continue }
                save()
                scheduleUpdate()
            }
        }
        Task { [weak self] in
            for await _ in Product.SubscriptionInfo.Status.updates {
                self?.scheduleUpdate()
            }
        }
    }

    /// Several of StoreKit's updates at once (a status and its transaction) make one check-in.
    private func scheduleUpdate() {
        updateSoon?.cancel()
        updateSoon = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await reread(sendAgain: false, reason: .update)
            await checkIns.checkIn(.update)
        }
    }

    /// Reads StoreKit's current entitlements and their subscriptions' renewal info: what gives access,
    /// and what taool hasn't seen, queued (`sendAgain`: all of it, for a restore or a new user).
    /// One at a time; a call while one runs waits for it, then reads again.
    private func reread(sendAgain: Bool, reason: CheckInReason) async {
        let previous = rereadChain
        let task = Task {
            await previous?.value
            await readStoreKit(sendAgain: sendAgain, reason: reason)
        }
        rereadChain = task
        await task.value
    }

    private func readStoreKit(sendAgain: Bool, reason: CheckInReason) async {
        var found: [Entitlement] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            state.queue(Self.pending(result), reason: reason, again: sendAgain)
            if let entitlement = Self.entitlement(transaction) { found.append(entitlement) }
        }
        // Purchases the app hasn't finished: taool hears of them too, as they may be news.
        for await result in StoreKit.Transaction.unfinished {
            if case .verified = result { state.queue(Self.pending(result), reason: reason) }
        }
        // Each group's renewal info: whether it renews, the grace period, and for taool, why it ends.
        for group in Set(found.compactMap(\.subscriptionGroupID)) {
            guard let statuses = try? await Product.SubscriptionInfo.status(for: group) else { continue }
            for status in statuses {
                guard case .verified(let renewal) = status.renewalInfo, case .verified(let transaction) = status.transaction else { continue }
                state.queue(Self.pending(status.renewalInfo), reason: reason, again: sendAgain)
                if let index = found.firstIndex(where: { $0.originalTransactionID == transaction.originalID }) {
                    found[index].willAutoRenew = renewal.willAutoRenew
                    found[index].state = status.state
                }
            }
        }
        state.cachedEntitlements = found
        readAt = .now
        if !isLoaded { isLoaded = true }
        save()
        recompute()
    }

    /// The entitlements and whether one is another user's, from StoreKit's and taool's last answer.
    private func recompute(now: Date = .now) {
        let signedIn = checkIns.userID != nil
        let otherUser = state.otherUserOf == checkIns.userID ? Set(state.otherUser) : []
        let merged = Entitlements.merge(storeKit: state.cachedEntitlements, otherUser: otherUser, grants: state.grants, signedIn: signedIn, now: now)
        if merged != currentEntitlements { currentEntitlements = merged }
        let used = Entitlements.isOnAnotherAccount(storeKit: state.cachedEntitlements, otherUser: otherUser, signedIn: signedIn)
        if used != isOnAnotherAccount { isOnAnotherAccount = used }
    }

    private func save() {
        guard state != saved else { return }
        file.write(state)
        saved = state
    }

    static func pending(_ transaction: VerificationResult<StoreKit.Transaction>) -> PurchasesState.Pending {
        pending("t", transaction.unsafePayloadValue.id, payload: transaction.payloadData, jws: transaction.jwsRepresentation)
    }

    static func pending(_ renewal: VerificationResult<Product.SubscriptionInfo.RenewalInfo>) -> PurchasesState.Pending {
        pending("r", renewal.unsafePayloadValue.originalTransactionID, payload: renewal.payloadData, jws: renewal.jwsRepresentation)
    }

    /// A signed item keyed by what it says: its ID and a hash of its payload without what changes
    /// whenever StoreKit signs it again (the date and the device verification), so only news (a refund,
    /// renewal turned off, a grace period) is sent again, never the same facts signed anew.
    nonisolated static func pending(_ kind: String, _ id: UInt64, payload: Data, jws: String) -> PurchasesState.Pending {
        var content = payload
        if var json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] {
            for field in ["signedDate", "deviceVerification", "deviceVerificationNonce"] { json[field] = nil }
            content = (try? JSONSerialization.data(withJSONObject: json, options: .sortedKeys)) ?? content
        }
        return .init(key: "\(kind)\(id).\(Hash.sha256(content).prefix(16))", jws: jws)
    }

    /// What a transaction gives access to: a subscription or a non-consumable. Never a consumable, which gives nothing
    /// lasting, nor a non-renewing subscription, which StoreKit keeps listing after it ends without saying how long it
    /// lasts, the app's own code deciding that; taool still hears of both.
    static func entitlement(_ t: StoreKit.Transaction) -> Entitlement? {
        guard t.productType == .autoRenewable || t.productType == .nonConsumable else { return nil }
        return Entitlement(productID: t.productID, purchaseDate: t.purchaseDate, originalPurchaseDate: t.originalPurchaseDate,
                           expirationDate: t.expirationDate, offer: offer(t), subscriptionGroupID: t.subscriptionGroupID,
                           originalTransactionID: t.originalID, ownershipType: t.ownershipType, environment: t.environment)
    }

    /// The transaction's offer, as `Transaction.offer` has it.
    static func offer(_ t: StoreKit.Transaction) -> Entitlement.Offer? {
        guard #available(iOS 17.2, macOS 14.2, tvOS 17.2, watchOS 10.2, visionOS 1.1, *) else {
            // Before Transaction.offer: an introductory offer at no price is a free trial.
            guard let type = t.offerType else { return nil }
            return .init(type: type, paymentMode: type == .introductory && t.price == 0 ? .freeTrial : nil, id: t.offerID)
        }
        guard let offer = t.offer else { return nil }
        let paymentMode: Product.SubscriptionOffer.PaymentMode? = switch offer.paymentMode {
        case .freeTrial?: .freeTrial
        case .payAsYouGo?: .payAsYouGo
        case .payUpFront?: .payUpFront
        default: nil
        }
        return .init(type: offer.type, paymentMode: paymentMode, id: offer.id)
    }
}

extension TaoolPurchases: CheckInContributor {
    package var pendingReason: CheckInReason? { state.pendingReason }

    /// StoreKit read again (not for a second scene a moment later), all of it for a new user.
    package func prepare(now: Date, userChanged: Bool) async {
        guard userChanged || now.timeIntervalSince(readAt ?? .distantPast) >= CheckIns.sameOpen else { return }
        // Marked before the read, so scenes becoming active together read StoreKit once.
        readAt = now
        await reread(sendAgain: userChanged, reason: userChanged ? .user : .launch)
    }

    /// What's queued, as much as a check-in carries.
    package func nextPart() -> (part: CheckInReport.Purchases, sent: [String]) {
        let transactions = Array(state.pending.filter { !$0.isRenewal }.prefix(Self.itemsPerCheckIn))
        let renewals = Array(state.pending.filter(\.isRenewal).prefix(Self.itemsPerCheckIn))
        let moving = transactions.filter { $0.moves == true }.map(\.transactionID)
        let part = CheckInReport.Purchases(transactions: transactions.isEmpty ? nil : transactions.map(\.jws),
                                           renewals: renewals.isEmpty ? nil : renewals.map(\.jws), moving: moving.isEmpty ? nil : moving)
        return (part, transactions.map(\.key) + renewals.map(\.key))
    }

    /// What a check-in carries at most of each kind of signed item, as taool takes.
    static let itemsPerCheckIn = 50

    /// taool's answer kept: a list left out stays as it was. What went is never sent again, whether taool
    /// took it, refused it, or the app isn't connected to Subscriptions yet.
    package func checkedIn(_ outcome: CheckInOutcome, sent: [String]) {
        state.markSent(sent)
        switch outcome {
        case .answered(let otherUser, let grants):
            if let otherUser { (state.otherUser, state.otherUserOf) = (otherUser, checkIns.userID) }
            if let grants { state.grants = grants }
        case .refused:
            // Sending it again for this user won't help either.
            log.error("taool refused a purchases report as invalid, so it's dropped.")
        }
        save()
        recompute()
    }

    package func userChanged() {
        recompute()
    }

    package var accessProducts: Set<String>? { isLoaded ? Set(currentEntitlements.map(\.productID)) : nil }
}

extension View {
    /// In-app purchases with taool, for the app: put it on the root view of each scene. It reads StoreKit
    /// as the app becomes active and as StoreKit reports changes, checks in with taool (TaoolAnalytics'
    /// check-in, which counts the app's users too) at a cold launch, when one is due and when there's news,
    /// never on every open, gives StoreKit's views below it the user's App Account Token, and puts
    /// `TaoolPurchases` in the environment.
    ///
    /// - Parameters:
    ///   - key: The account's key, from the taool app's TaoolKit page. Public: it's fine to ship in the app.
    ///   - userID: With accounts, who's signed in (any string; a UUID's `uuidString`), nil when no one is.
    ///     Pass it on every render, and signing in and out take effect; with TaoolKit's other modifiers, pass it the same.
    ///     A UUID also becomes Apple's App Account Token on purchases. Leave it out in an app without accounts.
    ///   - analytics: How much the device tells taool about itself (`TaoolAnalytics.Level`). `.automatic`
    ///     (recommended) is switched between standard and expanded in the taool app; any other level is a code override.
    ///   - bundleID: The App Store app's bundle ID, when a debug build uses a different one.
    public func taoolPurchases(key: String, userID: String? = nil, analytics: TaoolAnalytics.Level = .automatic,
                               bundleID: String? = nil) -> some View {
        TaoolPurchases.shared.configure(key: key, userID: userID, analytics: analytics, bundleID: bundleID)
        return modifier(TaoolPurchasesModifier())
    }
}

struct TaoolPurchasesModifier: ViewModifier {
    func body(content: Content) -> some View {
        let purchases = TaoolPurchases.shared
        content
            .environment(purchases)
            .inAppPurchaseOptions { _ in purchases.purchaseOptions }
            .modifier(TaoolAnalyticsModifier())
    }
}
