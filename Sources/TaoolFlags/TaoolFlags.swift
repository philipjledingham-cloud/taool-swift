// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import SwiftUI
@_exported import TaoolAnalytics

/// Feature flags you turn on from the taool app, with no app update: for a few users while you test, in TestFlight,
/// then for everyone once the version is out, at once or a step at a time. Make the flag in the taool app first (its
/// TaoolKit page, your app, Flags), then read it by its key:
///
/// ```swift
/// enum Flags: String, TaoolFlag {
///     case newOnboarding = "new-onboarding"
/// }
///
/// ContentView()
///     .taoolFlags(key: "taool_public_…")   // each scene's root view
///
/// if Flags.newOnboarding.isOn { NewOnboarding() }
/// ```
///
/// A flag can hold text, a number or JSON instead of on and off, for values the app reads (remote config), each read with
/// what it falls back to until the device has heard from taool:
///
/// ```swift
/// Text(Flags.paywallHeadline.string(default: "Unlock Pro"))
/// let days = Flags.trialDays.int(default: 7)
/// let plans = Flags.plans.value(as: [Plan].self, default: Plan.all)
/// ```
///
/// An on and off flag is off until the device has heard from taool, then has the last values it heard, kept on the
/// device, so reading one never waits on the network. New values apply as the app comes to the foreground or a user signs
/// in or out, never in the middle of a screen. Percentages, rollouts and targeting rules are worked out on the device, so
/// nothing about it is sent for them. It checks in through TaoolAnalytics, which it includes, for the users you pick by
/// hand.
public enum TaoolFlags {
    /// Whether the flag with this key is on for this user now. Off for a key taool doesn't know.
    @MainActor
    public static func isOn(_ key: String) -> Bool {
        FlagStore.shared.isOn(key)
    }

    /// The text the flag with this key gives this user now; `default` until the device has heard of it, or for a flag
    /// that isn't text.
    @MainActor
    public static func string(_ key: String, default fallback: String) -> String {
        if case .string(let value) = FlagStore.shared.value(key) { return value }
        return fallback
    }

    /// The number the flag with this key gives this user now; `default` until the device has heard of it, or for a flag
    /// that isn't a number.
    @MainActor
    public static func number(_ key: String, default fallback: Double) -> Double {
        if case .number(let value) = FlagStore.shared.value(key) { return value }
        return fallback
    }

    /// The whole number the flag with this key gives this user now; `default` until the device has heard of it, or for a
    /// flag that isn't a whole number.
    @MainActor
    public static func int(_ key: String, default fallback: Int) -> Int {
        if case .number(let value) = FlagStore.shared.value(key), let whole = Int(exactly: value) { return whole }
        return fallback
    }

    /// The JSON the flag with this key gives this user now, decoded as `type`; `default` until the device has heard of
    /// it, or when it doesn't decode as `type`.
    @MainActor
    public static func value<Value: Decodable>(_ key: String, as type: Value.Type = Value.self, default fallback: Value) -> Value {
        FlagStore.shared.decoded(key, as: type) ?? fallback
    }

    /// Turns a flag on or off on this device only, to check both sides of it. Only in DEBUG builds, and until the app quits.
    @MainActor
    public static func force(_ key: String, _ on: Bool) {
        #if DEBUG
        FlagStore.shared.force(key, on)
        #endif
    }
}

/// A feature flag made in the taool app: a case of a String enum, its raw value the flag's key.
///
/// ```swift
/// enum Flags: String, TaoolFlag {
///     case newOnboarding = "new-onboarding"
///     case widgets
/// }
/// ```
public protocol TaoolFlag: RawRepresentable<String> {}

extension TaoolFlag {
    /// Whether it's on for this user now.
    @MainActor
    public var isOn: Bool { TaoolFlags.isOn(rawValue) }

    /// Its text for this user now, or `default` until the device has heard of it.
    @MainActor
    public func string(default fallback: String) -> String { TaoolFlags.string(rawValue, default: fallback) }

    /// Its number for this user now, or `default` until the device has heard of it.
    @MainActor
    public func number(default fallback: Double) -> Double { TaoolFlags.number(rawValue, default: fallback) }

    /// Its whole number for this user now, or `default` until the device has heard of it.
    @MainActor
    public func int(default fallback: Int) -> Int { TaoolFlags.int(rawValue, default: fallback) }

    /// Its JSON for this user now, decoded as `type`, or `default` until the device has heard of it.
    @MainActor
    public func value<Value: Decodable>(as type: Value.Type = Value.self, default fallback: Value) -> Value {
        TaoolFlags.value(rawValue, as: type, default: fallback)
    }

    /// Turns it on or off on this device only. Only in DEBUG builds, and until the app quits.
    @MainActor
    public func force(_ on: Bool) { TaoolFlags.force(rawValue, on) }
}

extension View {
    /// Reads your app's feature flags from taool: put it on the root view of each scene. It asks for them at each launch, then
    /// as the app comes to the foreground once a minute has passed, and checks in through TaoolAnalytics for the users you
    /// pick by hand.
    ///
    /// - Parameters:
    ///   - key: The account's key, from the taool app's TaoolKit page. Public: it's fine to ship in the app.
    ///   - userID: Your own ID for the signed-in user, or nil while no one is signed in, so a user you pick by it in the
    ///     taool app gets their values on every device. Pass the current user each time, so signing in and out take effect;
    ///     with TaoolKit's other modifiers, pass it the same.
    ///   - analytics: How much the device tells taool about itself (`TaoolAnalytics.Level`). `.automatic` (recommended) is
    ///     switched between standard and expanded in the taool app; any other level is a code override.
    ///   - bundleID: The App Store app's bundle ID, when a debug build uses a different one.
    public func taoolFlags(key: String, userID: String? = nil, analytics: TaoolAnalytics.Level = .automatic,
                           bundleID: String? = nil) -> some View {
        CheckIns.shared.start(.flags, key: key, level: analytics, userID: userID, bundleID: bundleID)
        // The check-in's scenes say when the app comes to the foreground, which is when the flags' new values apply.
        CheckIns.shared.attach(flags: FlagStore.shared)
        return modifier(TaoolAnalyticsModifier())
    }
}
