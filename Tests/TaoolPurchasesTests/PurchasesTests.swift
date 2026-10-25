// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
@testable import TaoolAnalytics
import TaoolCore
import Testing
@testable import TaoolPurchases

private typealias Entitlement = TaoolPurchases.Entitlement

private func subscription(_ original: UInt64, product: String = "pro.yearly", ends: Date?, grace: Bool = false) -> Entitlement {
    .init(productID: product, purchaseDate: nil, originalPurchaseDate: nil, expirationDate: ends, offer: nil,
          subscriptionGroupID: ends == nil ? nil : "21000001", originalTransactionID: original, willAutoRenew: ends != nil,
          state: ends == nil ? nil : grace ? .inGracePeriod : .subscribed)
}

@Suite struct AskingTests {
    @Test @MainActor func byProductAndForDetails() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())/purchases.json")
        var state = PurchasesState()
        // A city guide bought for good, and a subscription.
        state.cachedEntitlements = [subscription(1, product: "guide.paris", ends: nil),
                                    subscription(2, product: "pro.yearly", ends: Date.now.addingTimeInterval(86_400))]
        StateFile<PurchasesState>(url: url).write(state)
        let purchases = TaoolPurchases(file: StateFile(url: url), checkIns: CheckIns(file: StateFile(url: url.deletingLastPathComponent().appending(path: "check-in.json"))))
        #expect(purchases.hasAccess && purchases.has("guide.paris") && !purchases.has("guide.rome"))
        #expect(purchases.has("pro.monthly", "pro.yearly"), "any of several")
        #expect(purchases.currentEntitlement(for: "pro.monthly", "pro.yearly")?.willAutoRenew == true)
        #expect(purchases.currentEntitlement(for: "guide.paris")?.expirationDate == nil && purchases.currentEntitlement(for: "guide.rome") == nil)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

@Suite struct EntitlementsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func storeKitsLessAnotherUsersPlusGrants() {
        let mine = subscription(1, ends: now.addingTimeInterval(86_400))
        let moved = subscription(2, product: "pro.monthly", ends: now.addingTimeInterval(3_600))
        let grants = [Grant(productId: "pro.lifetime", expirationDate: nil), Grant(productId: "pro.old", expirationDate: now.addingTimeInterval(-1)),
                      Grant(productId: "pro.yearly", expirationDate: now.addingTimeInterval(999_999))]
        let merged = Entitlements.merge(storeKit: [moved, mine], otherUser: ["2"], grants: grants, signedIn: true, now: now)
        // Another user's is gone, an ended grant and one for a product StoreKit has add nothing, a grant without an end lasts longest.
        #expect(merged.map(\.productID) == ["pro.lifetime", "pro.yearly"])
        #expect(merged.first?.isGrant == true)
        #expect(Entitlements.isOnAnotherAccount(storeKit: [moved, mine], otherUser: ["2"], signedIn: true))
    }

    @Test func aProductGivenTwiceIsOneGrant_TheLongest() {
        let grants = [Grant(productId: "pro.yearly", expirationDate: now.addingTimeInterval(86_400)),
                      Grant(productId: "pro.yearly", expirationDate: now.addingTimeInterval(999_999))]
        let merged = Entitlements.merge(storeKit: [], otherUser: [], grants: grants, signedIn: false, now: now)
        #expect(merged.map(\.expirationDate) == [now.addingTimeInterval(999_999)])
    }

    @Test func signedOutNothingIsAnotherUsers() {
        let moved = subscription(2, ends: now.addingTimeInterval(3_600))
        #expect(Entitlements.merge(storeKit: [moved], otherUser: ["2"], grants: [], signedIn: false, now: now) == [moved])
        #expect(!Entitlements.isOnAnotherAccount(storeKit: [moved], otherUser: ["2"], signedIn: false))
    }

    @Test func aCachedCopyPastItsEndIsDroppedUnlessInGrace() {
        let ended = subscription(1, ends: now.addingTimeInterval(-60))
        let inGrace = subscription(2, ends: now.addingTimeInterval(-60), grace: true)
        #expect(Entitlements.merge(storeKit: [ended, inGrace], otherUser: [], grants: [], signedIn: false, now: now) == [inGrace])
    }
}

@Suite struct StateTests {
    @Test func queuesOnceAndRemembersWhatWasSent() {
        var state = PurchasesState()
        let item = PurchasesState.Pending(key: "t1.100", jws: "a.b.c")
        let first = state.queue(item, reason: .launch)
        let twice = state.queue(item, reason: .launch)
        #expect(first && !twice, "queued once")
        state.markSent(["t1.100"])
        #expect(state.pending.isEmpty && state.pendingReason == nil)
        let afterSent = state.queue(item, reason: .launch)
        #expect(!afterSent, "taool has it")
        let restored = state.queue(item, reason: .restore, again: true)
        #expect(restored && state.pendingReason == .restore, "a restore sends it again")
        let weaker = state.queue(.init(key: "t2.1", jws: "x"), reason: .update)
        #expect(weaker && state.pendingReason == .restore, "the strongest reason stays")
    }

    @Test func aPurchaseOrRestoreMarksWhatMoves_EvenOnceQueued() {
        var state = PurchasesState()
        state.queue(.init(key: "t1.1", jws: "a"), reason: .user)
        state.queue(.init(key: "t2.1", jws: "b"), reason: .update)
        // A purchase of what's queued already: it moves now, and the check-in's reason is the purchase's.
        let again = state.queue(.init(key: "t2.1", jws: "b"), reason: .purchase, again: true)
        #expect(!again && state.pendingReason == .purchase)
        #expect(state.pending.map(\.moves) == [nil, true], "the other user's subscription queued with it doesn't move")
        #expect(state.pending.map(\.transactionID) == ["1", "2"])
    }

    @Test func queuesAndRemembersAreBounded() {
        var state = PurchasesState()
        for index in 0..<(PurchasesState.maxPending + 10) { state.queue(.init(key: "t\(index)", jws: "x"), reason: .launch) }
        #expect(state.pending.count == PurchasesState.maxPending)
        #expect(state.pending.first?.key == "t10", "the oldest go first")
        for index in 0..<(PurchasesState.maxSent + 5) { state.markSent(["s\(index)"]) }
        #expect(state.sent.count == PurchasesState.maxSent)
        #expect(!state.sent.contains("s0") && state.sent.contains("s\(PurchasesState.maxSent + 4)"))
    }

    @Test func keyedByWhatTheyStayNotWhenAppleSignedThem() throws {
        func renewal(_ payload: [String: Any]) throws -> PurchasesState.Pending {
            TaoolPurchases.pending("r", 7, payload: try JSONSerialization.data(withJSONObject: payload), jws: "h.p.s")
        }
        let first = try renewal(["originalTransactionId": "7", "autoRenewStatus": 1, "signedDate": 1, "deviceVerificationNonce": "a"])
        let resigned = try renewal(["originalTransactionId": "7", "autoRenewStatus": 1, "signedDate": 2, "deviceVerificationNonce": "b",
                                    "deviceVerification": "c"])
        let turnedOff = try renewal(["originalTransactionId": "7", "autoRenewStatus": 0, "signedDate": 3])
        #expect(first.key == resigned.key, "signed again, nothing new")
        #expect(first.key != turnedOff.key && first.isRenewal)
    }

    @Test func keptInAFileAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())/purchases.json")
        let file = StateFile<PurchasesState>(url: url)
        #expect(file.read() == nil)
        var state = PurchasesState()
        state.queue(.init(key: "t1.1", jws: "a.b.c"), reason: .purchase)
        state.grants = [Grant(productId: "pro", expirationDate: Date(timeIntervalSince1970: 1_800_000_000))]
        state.cachedEntitlements = [subscription(7, ends: Date(timeIntervalSince1970: 1_800_000_000))]
        file.write(state)
        #expect(StateFile(url: url).read() == state)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

@Suite struct CheckInPartTests {
    /// A TaoolPurchases with `state` kept already, and a check-in of its own, in a folder of their own.
    @MainActor private func purchases(_ state: PurchasesState = PurchasesState()) -> (TaoolPurchases, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())")
        let file = StateFile<PurchasesState>(url: folder.appending(path: "purchases.json"))
        file.write(state)
        return (TaoolPurchases(file: file, checkIns: CheckIns(file: StateFile(url: folder.appending(path: "check-in.json")))), folder)
    }

    @Test @MainActor func itsPartCarriesTheUserAndWhatsQueued() throws {
        let (empty, emptyFolder) = purchases()
        // Nothing queued: the part still goes, with who's signed in.
        let nothing = empty.nextPart()
        #expect(nothing.part == .init(transactions: nil, renewals: nil) && nothing.sent.isEmpty)

        var state = PurchasesState()
        state.queue(.init(key: "t1.1", jws: "t.jws.sig"), reason: .purchase)
        state.queue(.init(key: "r1.1", jws: "r.jws.sig"), reason: .update)
        let (queued, queuedFolder) = purchases(state)
        let next = queued.nextPart()
        #expect(next.part == .init(transactions: ["t.jws.sig"], renewals: ["r.jws.sig"], moving: ["1"]))
        #expect(next.sent == ["t1.1", "r1.1"] && queued.pendingReason == .purchase)
        try FileManager.default.removeItem(at: emptyFolder)
        try FileManager.default.removeItem(at: queuedFolder)
    }

    @Test @MainActor func whatWentIsNotSentAgain() throws {
        var state = PurchasesState()
        state.queue(.init(key: "t1.1", jws: "t.jws.sig"), reason: .purchase)
        let (purchases, folder) = purchases(state)
        let next = purchases.nextPart()
        // As for an app not connected to Subscriptions yet: no lists, and what went counts as handled.
        purchases.checkedIn(.answered(otherUser: nil, grants: nil), sent: next.sent)
        #expect(purchases.pendingReason == nil, "not sent again and again")
        #expect(purchases.nextPart().sent.isEmpty)
        try FileManager.default.removeItem(at: folder)
    }

    @Test @MainActor func whatsAnotherUsersIsForTheUserItWasAnsweredFor() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())")
        var signedIn = CheckInState()
        signedIn.userID = "player-a"
        StateFile<CheckInState>(url: folder.appending(path: "check-in.json")).write(signedIn)
        var state = PurchasesState()
        state.cachedEntitlements = [subscription(2, ends: Date.now.addingTimeInterval(86_400))]
        (state.otherUser, state.otherUserOf) = (["2"], "player-a")
        let file = StateFile<PurchasesState>(url: folder.appending(path: "purchases.json"))
        file.write(state)
        let checkIns = CheckIns(file: StateFile(url: folder.appending(path: "check-in.json")))
        let purchases = TaoolPurchases(file: file, checkIns: checkIns)
        #expect(!purchases.hasAccess && purchases.isOnAnotherAccount, "player B's, restored on another device")
        // Player B signs in here: StoreKit's answer stands until taool answers for them.
        checkIns.start(.purchases, key: "taool_key", level: .automatic, userID: "player-b", bundleID: nil)
        await Task.yield()
        #expect(purchases.hasAccess && !purchases.isOnAnotherAccount)
        // A again, with taool out of reach: what it said about A holds.
        checkIns.start(.purchases, key: "taool_key", level: .automatic, userID: "player-a", bundleID: nil)
        await Task.yield()
        #expect(!purchases.hasAccess)
        try FileManager.default.removeItem(at: folder)
    }

    @Test @MainActor func aUUIDInAnyFormIsTheAppAccountToken() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())")
        let checkIns = CheckIns(file: StateFile(url: folder.appending(path: "check-in.json")))
        let purchases = TaoolPurchases(file: StateFile(url: folder.appending(path: "purchases.json")), checkIns: checkIns)
        let token = try #require(UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        for form in ["E621E1F8-C36C-495A-93FC-0C247A3E6E5F", "e621e1f8c36c495a93fc0c247a3e6e5f"] {
            checkIns.start(.purchases, key: "taool_key", level: .automatic, userID: form, bundleID: nil)
            #expect(purchases.purchaseOptions == [.appAccountToken(token)], "\(form)")
        }
        checkIns.start(.purchases, key: "taool_key", level: .automatic, userID: "player-a", bundleID: nil)
        #expect(purchases.purchaseOptions.isEmpty, "not a UUID")
    }

    @Test @MainActor func anAnswerKeepsWhatItLeavesOut() throws {
        let (purchases, folder) = purchases()
        purchases.checkedIn(.answered(otherUser: nil, grants: [Grant(productId: "pro", expirationDate: nil)]), sent: [])
        #expect(purchases.has("pro"), "the grant gives access")
        purchases.checkedIn(.answered(otherUser: nil, grants: nil), sent: [])
        #expect(purchases.has("pro"), "a list left out stays as it was")
        try FileManager.default.removeItem(at: folder)
    }
}
