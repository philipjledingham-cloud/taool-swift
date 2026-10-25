// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import StoreKit
import SwiftUI
import TaoolCore

/// A/B tests. Declare an experiment as an enum of its variants (see `TaoolExperiment`), read
/// `.variant` where it shows, and record the goals it's meant to move. taool shows how often
/// each variant's users reach each goal: yours, and free trials and payments, which it
/// picks up by itself. End it in the taool app with a winner, and everyone sees the winner
/// without an app update.
///
/// ```swift
/// ContentView()
///     .taoolExperiments(key: "taool_public_…")
///
/// TaoolExperiments.record("feature-used")                  // one of your goals
/// TaoolExperiments.record(try await product.purchase())    // a purchase, counted at once
/// ```
///
/// Nothing blocks the app or throws. Variants are worked out on the device, so they need
/// no network, and reports wait until taool can be reached.
public enum TaoolExperiments {
    /// Records a purchase made in the app, so it counts for the user's variants right
    /// away. StoreKit doesn't announce purchases made in the app, so without this they're
    /// picked up from StoreKit's history at the next launch.
    public static func record(_ result: Product.PurchaseResult) {
        guard case .success(let verification) = result else { return }
        let transaction = verification.unsafePayloadValue
        ExperimentStore.shared.addTransaction(id: transaction.id, purchase: transaction.originalID,
                                              jws: verification.jwsRepresentation, startedAt: transaction.originalPurchaseDate)
    }

    /// Records that the user reached one of your goals: finished onboarding, used a
    /// feature, signed up. It counts for every variant they've seen before it; call
    /// it every time, and it's sent once per experiment shown. Name goals like experiment
    /// keys: letters, digits, ".", "_" and "-", up to 64.
    public static func record(_ goal: String) {
        ExperimentStore.shared.addGoal(goal)
    }

    /// Shows a variant on this device without counting it, to check each variant's UI.
    /// Only in DEBUG builds, and until the app quits.
    public static func force<Experiment: TaoolExperiment>(_ variant: Experiment) {
        #if DEBUG
        ExperimentStore.shared.force(experiment: Experiment.key, variant: variant.rawValue)
        #endif
    }
}

extension View {
    /// Runs the app's experiments with taool: as the app comes to the foreground, it asks
    /// which experiments have ended (a winner shows from the next time, never in the middle
    /// of a screen) and reports new exposures and purchases. Put it on the root view of each
    /// scene.
    ///
    /// - Parameters:
    ///   - key: The account's key, from the taool app's TaoolKit page. Public: it's fine to ship
    ///     in the app.
    ///   - userID: Your own ID for the signed-in user, or nil while no one is signed in: then
    ///     Apple's appTransactionID, one per Apple Account and app, the same on every device and
    ///     after a reinstall. Only a SHA-256 of it leaves the device. When a user signs in, what
    ///     they did signed out moves over to them; signing out or switching accounts never
    ///     merges anyone. Pass the current user each time, so signing in and out take effect.
    ///   - bundleID: The App Store app's bundle ID, when a debug build uses a different one.
    public func taoolExperiments(key: String, userID: String? = nil, bundleID: String? = nil) -> some View {
        // Here rather than in the modifier's task, so it's set before the content reads a variant.
        ExperimentStore.shared.setUser(userID)
        return modifier(TaoolExperimentsModifier(key: key, bundleID: bundleID))
    }
}

struct TaoolExperimentsModifier: ViewModifier {
    let key: String
    let bundleID: String?

    func body(content: Content) -> some View {
        content.modifier(SceneUse { [key, bundleID] in
            await ExperimentReporter.shared.becameActive(scene: $0, key: key, bundleID: bundleID)
        } left: {
            await ExperimentReporter.shared.left(scene: $0)
        })
    }
}
