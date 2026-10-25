// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation

/// Whether this install is out of date, from `TaoolUpdates.status(key:)`.
public enum UpdateStatus: Sendable, Equatable {
    /// Up to date, or taool couldn't be reached and nothing was known before.
    case current
    /// A newer version this device can install is on the App Store.
    case available(AppRelease)
    /// This version is below the developer's minimum, and the release shown installs on
    /// this device. The app shouldn't be used until it's updated.
    case required(AppRelease)
    /// This version must update, but no version at or above the minimum runs on this OS.
    /// `requiredOSVersion` is the oldest OS a version at or above the minimum runs on, when known.
    case unsupported(requiredOSVersion: String?)
}

/// A version on the App Store, and the link to it. Its notes are on that App Store page.
public struct AppRelease: Sendable, Equatable {
    public let version: String
    /// Opens the app's page in the App Store app.
    public let appStoreURL: URL

    public init(version: String, appStoreURL: URL) {
        self.version = version
        self.appStoreURL = appStoreURL
    }

    /// The App Store app's own URL scheme, so the link skips the browser.
    static func appStoreURL(appId: Int64) -> URL {
        #if os(macOS)
        URL(string: "macappstore://apps.apple.com/app/id\(appId)")!
        #else
        URL(string: "itms-apps://apps.apple.com/app/id\(appId)")!
        #endif
    }
}

/// Fake statuses for trying out the update UI. Only honored in DEBUG builds.
public enum UpdateSimulation: Sendable {
    case available
    case required
    case unsupported

    var status: UpdateStatus {
        let release = AppRelease(version: "99.0", appStoreURL: URL(string: "https://apps.apple.com")!)
        switch self {
        case .available: return .available(release)
        case .required: return .required(release)
        case .unsupported: return .unsupported(requiredOSVersion: "99.0")
        }
    }
}
