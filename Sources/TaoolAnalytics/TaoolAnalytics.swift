// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import SwiftUI
import TaoolCore

/// Who uses your app, with taool: each Apple Account that opens it checks in now and then, so taool
/// counts your users (weekly and monthly, daily with expanded analytics) and the versions they're on.
/// No sign-in, no Subscriptions and no server needed.
///
/// ```swift
/// ContentView()
///     .taoolAnalytics(key: "taool_public_…")   // each scene's root view
/// ```
///
/// It's one check-in however many of TaoolKit's products the app links: TaoolPurchases and TaoolFlags check in through it
/// too, so an app with either needs no `.taoolAnalytics`. Nothing blocks the app or throws, and nothing goes on every open.
public enum TaoolAnalytics {
    /// This user's Apple Account in your app, StoreKit's appTransactionID, for a support or debug screen: find the user by
    /// it in the taool app, to pick them for a flag or give them access. Nil while StoreKit can't say.
    ///
    /// ```swift
    /// Text(accountID ?? "…")
    ///     .task { accountID = await TaoolAnalytics.appTransactionID() }
    /// ```
    @MainActor public static func appTransactionID() async -> String? {
        await AppTransactionFacts.read()?.id
    }

    /// How much the device tells taool about itself. Leave it at `.automatic` (recommended) to switch between
    /// standard and expanded in the taool app, with no app update; any other level is a code override, which
    /// the taool app can't change, and shows beside its switch. Set with the `analytics:` of `.taoolAnalytics`, `.taoolPurchases` or `.taoolFlags`;
    /// when the code asks for more than one level, the most private holds.
    public enum Level: Sendable, Hashable {
        /// **Recommended**, and the default: standard or expanded, switched in the taool app (TaoolKit →
        /// Analytics → the app), standard until you turn Expanded Analytics on there. The only level the
        /// taool app can change.
        case automatic
        /// A code override: nothing about the device, only which Apple Account this is, the user ID you pass,
        /// and with TaoolPurchases the signed purchases access needs. taool then can't show which versions or
        /// countries your users are on.
        case minimal
        /// A code override: the app's version and build, TaoolKit's version, the platform, the App Store
        /// country, the language the app runs in, the device's preferred language and its region, never more,
        /// even with Expanded Analytics on in the taool app.
        case standard
        /// A code override: standard, and when the app was last opened and how often, the OS version and the
        /// kind of device and its model, even with Expanded Analytics off in the taool app.
        case expanded

        /// The level a check-in sends (never `.automatic`): the code's, else the taool app's
        /// (standard until it has said).
        package func level(remote: String?) -> Level {
            guard self == .automatic else { return self }
            return remote == "expanded" ? .expanded : .standard
        }

        /// As the check-in sends it: 0 automatic, then the code's levels, the most private first.
        package var number: Int {
            switch self {
            case .automatic: 0
            case .minimal: 1
            case .standard: 2
            case .expanded: 3
            }
        }

        /// The most private of the levels the code asks for, `.automatic` where it asks for none.
        package static func mostPrivate(_ levels: some Sequence<Level>) -> Level {
            levels.filter { $0 != .automatic }.min { $0.number < $1.number } ?? .automatic
        }
    }
}

extension View {
    /// Counts the app's users with taool: put it on the root view of each scene. It checks in at a cold launch,
    /// then as the app becomes active or leaves when one is due (about every 6 hours), never on every open.
    /// With TaoolPurchases or TaoolFlags, their modifier checks in already, so this isn't needed.
    ///
    /// - Parameters:
    ///   - key: The account's key, from the taool app's TaoolKit page. Public: it's fine to ship in the app.
    ///   - userID: With accounts, your own ID for the signed-in user (any string; a UUID's `uuidString`), nil when no one
    ///     is, so the taool app finds and groups a user's Apple Accounts by it. Pass it on every render, and signing in and
    ///     out take effect; with TaoolKit's other modifiers, pass it the same. Leave it out in an app without accounts.
    ///   - analytics: How much the device tells taool about itself (`TaoolAnalytics.Level`). `.automatic`
    ///     (recommended) is switched between standard and expanded in the taool app; any other level is a code override.
    ///   - bundleID: The App Store app's bundle ID, when a debug build uses a different one.
    public func taoolAnalytics(key: String, userID: String? = nil, analytics: TaoolAnalytics.Level = .automatic,
                               bundleID: String? = nil) -> some View {
        CheckIns.shared.start(.analytics, key: key, level: analytics, userID: userID, bundleID: bundleID)
        return modifier(TaoolAnalyticsModifier())
    }
}

/// The check-in's part of a scene: as it becomes active, and as it goes to the background or closes, the app leaving only
/// with the last of its scenes (an iPad's or a Mac's windows). TaoolPurchases' and TaoolFlags' modifiers apply it too.
package struct TaoolAnalyticsModifier: ViewModifier {
    package init() {}

    package func body(content: Content) -> some View {
        content.modifier(SceneUse { await CheckIns.shared.becameActive(scene: $0) } left: { await CheckIns.shared.left(scene: $0) })
    }
}
