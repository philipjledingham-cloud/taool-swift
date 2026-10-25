// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import TaoolCore

/// What the update check answers: the developer's policy and the app's versions. The device
/// works out what it means for itself (`status`).
struct UpdatePolicy: Codable, Equatable, Sendable {
    let appId: Int64
    /// Installed versions older than this must update.
    let minimumVersion: String?
    /// Newest first: lets a device on an older OS find the newest version it can install.
    let versions: [Version]
    /// The What's New page to show.
    var whatsNew: WhatsNewPage? = nil
    /// The pages TestFlight builds see before they're live, newest first: the newest at or below the build's version,
    /// when it's about a newer version than `whatsNew` (`WhatsNewPage.shown`).
    var testFlightPages: [WhatsNewPage]? = nil
    /// The language the developer locked the prompts to in the taool app, BCP 47. Nil: the app's.
    var language: String? = nil
    /// The developer's own text for the banner and the update-required screen.
    var messages: [UpdateMessage]? = nil

    struct Version: Codable, Equatable, Sendable {
        let version: String
        let minimumOsVersion: String?
    }

    /// What this policy means for an install of `appVersion` on `osVersion`.
    ///
    /// The App Store gives a device on an older OS the newest version that still supports
    /// it, so "the version you can update to" is the newest version whose minimum OS this
    /// device meets, not simply the latest. A version whose minimum OS isn't known counts as one
    /// this device can install: the App Store then offers what it can, rather than the app saying
    /// nothing runs on this OS.
    func status(appVersion: String, osVersion: String) -> UpdateStatus {
        let installable = versions.first { version in
            let runsHere = version.minimumOsVersion.map { !Versions.isNewer($0, than: osVersion) } ?? true
            return runsHere && meetsMinimum(version.version)
        }
        let update = installable.flatMap {
            Versions.isNewer($0.version, than: appVersion) ? AppRelease(version: $0.version, appStoreURL: AppRelease.appStoreURL(appId: appId)) : nil
        }

        if !meetsMinimum(appVersion) {
            if let update { return .required(update) }
            // The oldest OS a version at or above the minimum runs on, never simply the latest's: 2.0 may need 26 while
            // 1.9, enough for the minimum, runs on 18.
            let neededOS = versions.filter { meetsMinimum($0.version) }.compactMap(\.minimumOsVersion)
                .min { Versions.isNewer($1, than: $0) }
            return .unsupported(requiredOSVersion: neededOS)
        }
        if let update { return .available(update) }
        return .current
    }

    private func meetsMinimum(_ version: String) -> Bool {
        guard let minimumVersion else { return true }
        return !Versions.isNewer(minimumVersion, than: version)
    }
}
