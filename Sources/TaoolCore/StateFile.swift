// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import os

/// A state a `StateFile` keeps: `init()` is a fresh install's.
package protocol FileState: Codable, Sendable {
    init()
}

/// A state kept on the device in a file of its own, written whole and atomically: never in the app's defaults, which the
/// app's own code reads, syncs and clears. Each of TaoolKit's products keeps its own.
package final class StateFile<State: FileState>: Sendable {
    private let url: URL
    /// The file is there but couldn't be read, as before the device's first unlock: never written over this launch.
    private let isLocked = OSAllocatedUnfairLock(initialState: false)
    private let log = Logger(subsystem: "TaoolKit", category: "state")

    package init(url: URL) {
        self.url = url
    }

    /// The app's own: Application Support/<bundle ID>/TaoolKit/`name`, in the bundle ID's folder since a Mac app outside the
    /// sandbox shares Application Support with every other app. On tvOS, Caches, the one folder an app keeps files in there,
    /// which the system may empty: TaoolKit then starts as on a fresh install.
    package static func inAppSupport(_ name: String) -> StateFile {
        #if os(tvOS)
        let folder = URL.cachesDirectory
        #else
        let folder = URL.applicationSupportDirectory
        #endif
        return StateFile(url: folder.appending(path: "\(Bundle.main.bundleIdentifier ?? "app")/TaoolKit/\(name)"))
    }

    /// What was kept; nil when nothing was. A file from before a field was added reads with that field as a fresh state has
    /// it (a field added inside a list's items is optional, so it reads as nil). One that still can't be read is moved
    /// aside, never written over, and the state starts fresh.
    package func read() -> State? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if (error as? CocoaError)?.code != .fileReadNoSuchFile { isLocked.withLock { $0 = true } }
            return nil
        }
        if let state = try? Kit.decoder.decode(State.self, from: data) { return state }
        if let kept = try? JSONSerialization.jsonObject(with: data),
           let fresh = try? JSONSerialization.jsonObject(with: Kit.encoder.encode(State())),
           let merged = try? JSONSerialization.data(withJSONObject: Self.merge(kept, over: fresh)),
           let state = try? Kit.decoder.decode(State.self, from: merged) {
            return state
        }
        let aside = url.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        log.error("Couldn't read TaoolKit's \(self.url.lastPathComponent, privacy: .public), so it starts fresh.")
        return nil
    }

    package func write(_ state: State) {
        guard !isLocked.withLock({ $0 }) else { return }
        do {
            let data = try Kit.encoder.encode(state)
            do {
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                // The first write: its folder too, then once more.
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        } catch {
            log.error("Couldn't keep TaoolKit's \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `kept`'s values over `fresh`'s, object by object.
    private static func merge(_ kept: Any, over fresh: Any) -> Any {
        guard let kept = kept as? [String: Any], let fresh = fresh as? [String: Any] else { return kept }
        return fresh.merging(kept) { fresh, kept in merge(kept, over: fresh) }
    }
}
