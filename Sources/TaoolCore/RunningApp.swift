// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What the running build says about itself, read alike by every product.
package enum RunningApp {
    /// CFBundleShortVersionString, "2.5".
    package static var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    /// CFBundleVersion, "211".
    package static var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }

    /// The OS the build is for: "ios" (iPhone and iPad, and their apps on a Mac or Vision Pro), "macos" (a Mac app, Mac
    /// Catalyst's too), "tvos", "watchos" or "visionos".
    package static var platform: String {
        #if os(macOS) || targetEnvironment(macCatalyst)
        "macos"
        #elseif os(tvOS)
        "tvos"
        #elseif os(watchOS)
        "watchos"
        #elseif os(visionOS)
        "visionos"
        #else
        "ios"
        #endif
    }

    /// The kind of device: "phone", "pad", "mac", "watch", "tv" or "vision", which TaoolFlags' device rules compare. An iPad
    /// app on a Vision Pro is "pad", but on a Mac it's "mac", as Mac Catalyst is, so it agrees with the model sent.
    @MainActor package static var deviceKind: String {
        #if os(macOS)
        return "mac"
        #elseif os(watchOS)
        return "watch"
        #else
        if ProcessInfo.processInfo.isMacCatalystApp { return "mac" }
        return switch UIDevice.current.userInterfaceIdiom {
        case .pad: "pad"
        case .tv: "tv"
        case .vision: "vision"
        default: "phone"
        }
        #endif
    }

    /// "27.0.1".
    package static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The language the app runs in, "en" or "pt-BR": the first of its own localizations the user prefers, not the
    /// device's language, so an app only in English is English on a Swedish iPhone.
    package static var language: String {
        language(preferred: Bundle.main.preferredLocalizations, development: Bundle.main.developmentLocalization)
    }

    /// "Base", a folder rather than a language, is the development language, else English.
    package static func language(preferred: [String], development: String?) -> String {
        let language = [preferred.first, development].compactMap { $0 }.first { $0 != "Base" } ?? "en"
        return language.replacingOccurrences(of: "_", with: "-")
    }
}
