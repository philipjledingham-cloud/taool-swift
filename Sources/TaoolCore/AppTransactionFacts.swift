// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import StoreKit

/// StoreKit's record of the app for this Apple Account, its AppTransaction: read on the device once a launch, as soon as
/// StoreKit answers.
package struct AppTransactionFacts: Sendable {
    /// As Apple signed it, for taool to verify.
    package let signed: String
    /// The appTransactionID: the same for this Apple Account on every device and after a reinstall.
    package let id: String
    package let environment: AppStore.Environment
    /// When this Apple Account first downloaded the app; nil outside the App Store, whose sandbox gives every Apple Account
    /// the same fake date (1 August 2013).
    package let downloadedAt: Date?

    /// A TestFlight or development build.
    package var isTestBuild: Bool { environment != .production }

    package init(signed: String, id: String, environment: AppStore.Environment, downloadedAt: Date?) {
        (self.signed, self.id, self.environment, self.downloadedAt) = (signed, id, environment, downloadedAt)
    }

    /// This launch's, once read.
    @MainActor private static var current: AppTransactionFacts?
    /// A read on its way, which callers at the same moment (the check-in and the flags at launch) share.
    @MainActor private static var reading: Task<AppTransactionFacts?, Never>?

    /// The app's AppTransaction, whether StoreKit verified it or not: taool verifies what's sent, and nothing read here
    /// gives access.
    @MainActor package static func read() async -> AppTransactionFacts? {
        if let current { return current }
        let task = reading ?? Task { await ask() }
        reading = task
        current = await task.value
        reading = nil
        return current
    }

    @MainActor private static func ask() async -> AppTransactionFacts? {
        guard let result = try? await AppTransaction.shared else { return nil }
        let transaction = switch result {
        case .verified(let transaction), .unverified(let transaction, _): transaction
        }
        return AppTransactionFacts(signed: result.jwsRepresentation, id: transaction.appTransactionID,
                                   environment: transaction.environment,
                                   downloadedAt: transaction.environment == .production ? transaction.originalPurchaseDate : nil)
    }
}
