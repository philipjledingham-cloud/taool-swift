// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation

/// An A/B test. Its variants are the cases of a String enum, and the first case is the
/// control. taool shows each variant by its raw value.
///
/// ```swift
/// enum PaywallButton: String, TaoolExperiment {
///     case control
///     case freeTrial
/// }
///
/// var body: some View {
///     let button = PaywallButton.variant   // the same for every part of the screen
///     Text(button == .freeTrial ? "Try Pro free for 7 days" : "Unlock Pro")
///     Button(button == .freeTrial ? "Start Free Trial" : "Continue") { … }
/// }
/// ```
public protocol TaoolExperiment: RawRepresentable<String>, CaseIterable, Sendable {
    /// The experiment's name in taool: unless you set it, the type's name with the types it's
    /// nested in, "PaywallButton" or "PaywallView.Variant". Set it to keep the experiment and
    /// its results when you rename or move the type.
    static var key: String { get }
}

extension TaoolExperiment {
    public static var key: String {
        // "MyApp.PaywallView.Variant", with "(unknown context at $…)" in it for a private or local type: the names alone.
        String(reflecting: Self.self).split(separator: ".").dropFirst().filter { !$0.hasPrefix("(") }.joined(separator: ".")
    }

    /// The user's variant, the same every time and on every device: their own while the
    /// experiment runs, and the winner once you end it in taool. Reading it counts the user
    /// for their variant, so read it where the variant shows (in `body`), not ahead of time.
    public static var variant: Self {
        let cases = Array(allCases)
        precondition(!cases.isEmpty, "\(Self.self) needs a case: the first one is the control.")
        let name = ExperimentStore.shared.variant(experiment: key, variants: cases.map(\.rawValue))
        return cases.first { $0.rawValue == name } ?? cases[0]
    }
}
