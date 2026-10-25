// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import SwiftUI

/// The scenes in use, each by its modifier (`SceneUse`): the app comes to the foreground as the first becomes active, and
/// leaves as the last goes to the background or closes, never as another window opens or one comes back from Control
/// Center, whose screens are in use.
package struct ScenesInUse: Sendable {
    private var active: Set<UUID> = []

    package init() {}

    /// A scene became active; true when it's the app coming to the foreground.
    package mutating func becameActive(_ scene: UUID) -> Bool {
        let first = active.isEmpty
        active.insert(scene)
        return first
    }

    /// A scene went to the background or closed; true when it was the last in use, the app leaving. Never for a scene
    /// that never became active (one made as the app launched in the background).
    package mutating func left(_ scene: UUID) -> Bool {
        active.remove(scene) != nil && active.isEmpty
    }
}

/// A scene's part in `ScenesInUse`: `becameActive` as it becomes active, `left` as it goes to the background or closes.
package struct SceneUse: ViewModifier {
    private let becameActive: @MainActor @Sendable (UUID) async -> Void
    private let left: @MainActor @Sendable (UUID) async -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var scene = UUID()

    package init(becameActive: @escaping @MainActor @Sendable (UUID) async -> Void,
                 left: @escaping @MainActor @Sendable (UUID) async -> Void) {
        self.becameActive = becameActive
        self.left = left
    }

    package func body(content: Content) -> some View {
        content
            .task(id: scenePhase) {
                switch scenePhase {
                case .active: await becameActive(scene)
                case .background: await left(scene)
                default: break
                }
            }
            // A window closed, which needn't go to the background first.
            .onDisappear { Task { await left(scene) } }
    }
}
