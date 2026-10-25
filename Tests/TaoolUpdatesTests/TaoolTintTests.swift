// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import SwiftUI
import Testing
@testable import TaoolUpdates

@MainActor
struct TaoolTintTests {
    private func label(_ tint: TaoolTint) -> Color {
        var environment = EnvironmentValues()
        environment.taoolTint = tint
        return TaoolTintLabel().resolve(in: environment)
    }

    private func label(on red: Double, _ green: Double, _ blue: Double) -> Color {
        label(TaoolTint(fill: Color(red: red, green: green, blue: blue), label: nil))
    }

    @Test func lightFills_black() {
        #expect(label(on: 1, 0.8, 0) == .black, "a yellow")
        #expect(label(on: 0xec / 255, 0xdf / 255, 0xc5 / 255) == .black, "a pale gold")
    }

    @Test func darkerFills_white_asIOSLabelsThem() {
        #expect(label(on: 0, 0.48, 1) == .white, "the system's blue")
        #expect(label(on: 1, 0.58, 0) == .white, "the system's orange")
        #expect(label(on: 0x8a / 255, 0x72 / 255, 0x42 / 255) == .white, "a bronze")
    }

    @Test func aGivenLabel_asGiven() {
        #expect(label(TaoolTint(fill: Color(red: 1, green: 0.8, blue: 0), label: .white)) == .white, "no contrast check")
    }
}
