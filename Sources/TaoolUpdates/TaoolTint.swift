// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import SwiftUI

extension View {
    /// The colors the update prompts and What's New draw in: `color` fills the Update buttons and colors the icons, and
    /// `label` is the buttons' text. Without it they're the app's AccentColor, the label worked out as below. Like
    /// `.tint`, it reaches only what's inside it, so put it after `.taoolUpdatePrompts` and `.taoolWhatsNew`, or on a
    /// view around them.
    ///
    /// ```swift
    /// ContentView()
    ///     .taoolUpdatePrompts(key: "taool_public_…")
    ///     .taoolTint(.orange)                  // the label white or black, whichever reads
    ///  // .taoolTint(.yellow, label: .white)   // the label as given
    /// ```
    ///
    /// - Parameters:
    ///   - color: The buttons' fill and the icons. An asset catalog color with a dark appearance follows the appearance.
    ///   - label: The buttons' text, as given, with no contrast check; an asset catalog color follows the appearance too.
    ///     Nil: black on a light `color` (a yellow, a pale gold) and white otherwise, as iOS labels its blue, green and orange.
    public func taoolTint(_ color: Color, label: Color? = nil) -> some View {
        environment(\.taoolTint, TaoolTint(fill: color, label: label))
    }
}

/// `.taoolTint`'s colors.
struct TaoolTint: Equatable {
    let fill: Color
    let label: Color?
}

extension EnvironmentValues {
    @Entry var taoolTint = TaoolTint(fill: .accentColor, label: nil)
}

/// The Update buttons' label, resolved where it's drawn: the tint's, else black past a relative luminance of 0.5 and
/// white below, so the system's blue, green and orange keep white, as iOS draws them.
struct TaoolTintLabel: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        let tint = environment.taoolTint
        if let label = tint.label { return label }
        let fill = tint.fill.resolve(in: environment)
        let luminance = 0.2126 * fill.linearRed + 0.7152 * fill.linearGreen + 0.0722 * fill.linearBlue
        return luminance > 0.5 ? .black : .white
    }
}

/// TaoolKit's filled button, Update's in the prompts and What's New. `.borderedProminent` labels in white whatever the
/// fill, and a `.tint` can't be read, so it's filled with a color TaoolKit was given, which the label is worked out from.
struct AccentButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.taoolTint) private var tint

    var body: some View {
        Button(action: action) {
            label.foregroundStyle(TaoolTintLabel())
        }
        .buttonStyle(.borderedProminent)
        .tint(tint.fill)
    }
}
