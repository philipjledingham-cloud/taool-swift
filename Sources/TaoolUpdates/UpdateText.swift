// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import TaoolCore

/// Which prompt a message is for: the banner when an update is available, or the screen when
/// it's required.
enum UpdateMessageKind: String, Sendable {
    case available, required
}

/// What an update prompt says: the banner's or the update-required screen's.
public struct UpdatePromptText: Sendable, Equatable {
    public let title: String
    public let message: String
    /// The label for the button that opens the App Store: "Update". Show none for `.unsupported`:
    /// nothing on the App Store runs on this OS.
    public let button: String

    init(title: String, message: String, button: String) {
        self.title = title
        self.message = message
        self.button = button
    }
}

extension TaoolUpdates {
    /// The languages TaoolKit's own text comes in, BCP 47, English first.
    static let languages = [
        "en", "ar", "ca", "cs", "da", "de", "el", "es", "es-MX", "fi", "fr", "fr-CA", "he", "hi", "hr", "hu",
        "id", "it", "ja", "ko", "ms", "nb", "nl", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk", "sv", "th", "tr",
        "uk", "vi", "zh-Hans", "zh-Hant", "zh-HK",
    ]
}

extension UpdateStatus {
    /// What `.taoolUpdatePrompts(key:)` would say about this status, for your own UI: your message from
    /// the taool app, or TaoolKit's own text, in the language the app runs in or the one you
    /// locked the prompts to there. Nil when current.
    @MainActor public var text: UpdatePromptText? { UpdateState.shared.result.wording.text(for: self) }
}

/// A message the developer wrote in the taool app, in place of TaoolKit's own text on
/// the banner or the update-required screen.
struct UpdateMessage: Codable, Equatable, Sendable {
    /// "available" or "required". Any other, from a newer taool, is ignored.
    let kind: String
    /// The version it's about: the one offered (available) or the minimum (required). Nil for every version.
    var version: String? = nil
    /// Its text per language, BCP 47. `{version}` and `{app}` are filled in on the device.
    let texts: [String: String]
}

/// What the prompts say and in which language: TaoolKit's own text, or the developer's messages.
struct UpdateWording: Sendable, Equatable {
    /// The developer's lock, else the language the app runs in.
    let language: String
    let messages: [UpdateMessage]
    /// The policy's minimum: a required message about it wins over one for every version.
    let minimumVersion: String?
    let appName: String
    /// TaoolKit's own text in the closest of its languages to `language`.
    let strings: UpdateStrings

    /// TaoolKit's own text in the app's language, until a check says more.
    static let initial = UpdateWording(policy: nil)

    init(language: String, messages: [UpdateMessage] = [], minimumVersion: String? = nil, appName: String = Device.appName) {
        self.language = language
        self.messages = messages
        self.minimumVersion = minimumVersion
        self.appName = appName
        strings = UpdateStrings(language: language)
    }

    /// A policy's lock and messages; without a lock, the app's language.
    init(policy: UpdatePolicy?, appLanguage: String = RunningApp.language) {
        self.init(language: policy?.language ?? appLanguage, messages: policy?.messages ?? [], minimumVersion: policy?.minimumVersion)
    }

    /// The banner (`version` offered) or the update-required screen (`version` to update to, nil
    /// when it isn't known).
    func text(_ kind: UpdateMessageKind, version: String?) -> UpdatePromptText {
        switch kind {
        case .available:
            return UpdatePromptText(title: strings["banner.title"],
                                    message: custom(.available, version: version) ?? strings.format("banner.message", version ?? ""),
                                    button: strings["button.update"])
        case .required:
            let standard = version.map { strings.format("required.message", appName, $0) }
                ?? strings.format("required.messageNoVersion", appName)
            return UpdatePromptText(title: strings["required.title"], message: custom(.required, version: version) ?? standard,
                                    button: strings["button.update"])
        }
    }

    /// No version at or above the minimum runs on this OS: always TaoolKit's own text. `osName`
    /// is iOS or iPadOS (`Device.osName`); a Mac app's text names macOS itself.
    func unsupportedText(requiredOSVersion: String?, osName: String) -> UpdatePromptText {
        let message: String
        if let requiredOSVersion {
            #if os(macOS) || targetEnvironment(macCatalyst)
            message = strings.format("unsupported.messageMac", appName, requiredOSVersion)
            #else
            message = strings.format("unsupported.messageIOS", appName, osName, requiredOSVersion)
            #endif
        } else {
            message = strings.format("unsupported.message", appName)
        }
        return UpdatePromptText(title: strings["unsupported.title"], message: message, button: strings["button.update"])
    }

    @MainActor func text(for status: UpdateStatus) -> UpdatePromptText? {
        switch status {
        case .current: nil
        case .available(let release): text(.available, version: release.version)
        case .required(let release): text(.required, version: release.version)
        case .unsupported(let os): unsupportedText(requiredOSVersion: os, osName: Device.osName)
        }
    }

    @MainActor func text(for cover: UpdateCover) -> UpdatePromptText {
        switch cover {
        case .required(let release, _): text(.required, version: release?.version)
        case .unsupported(let os): unsupportedText(requiredOSVersion: os, osName: Device.osName)
        }
    }

    /// The developer's message, placeholders filled in: the one about `version` (available) or
    /// the minimum (required) first, then the one for every version, whichever has this language.
    /// Nil for TaoolKit's own, as with `{version}` when the version isn't known.
    private func custom(_ kind: UpdateMessageKind, version: String?) -> String? {
        let about = kind == .available ? version : minimumVersion
        let ofKind = messages.filter { $0.kind == kind.rawValue }
        let candidates = ofKind.filter { message in
            guard let own = message.version, let about else { return false }
            return Versions.isSame(own, about)
        } + ofKind.filter { $0.version == nil }

        for message in candidates {
            guard let language = UpdateLanguage.closest(to: language, in: Array(message.texts.keys)),
                  let text = message.texts[language]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { continue }
            if text.contains("{version}") && version == nil { continue }
            return text.replacingOccurrences(of: "{version}", with: version ?? "").replacingOccurrences(of: "{app}", with: appName)
        }
        return nil
    }
}

/// TaoolKit's own text in one of its languages, read from that language's table rather than
/// through `Bundle.module`'s lookup, which follows the device's languages and not the app's.
struct UpdateStrings: Sendable, Equatable {
    /// One of `TaoolUpdates.languages`.
    let language: String

    init(language: String) {
        self.language = UpdateLanguage.closest(to: language, in: TaoolUpdates.languages) ?? "en"
    }

    /// The text, or English's where this language lacks it.
    subscript(key: String) -> String {
        let english = Self.tables["en"]?.localizedString(forKey: key, value: key, table: nil) ?? key
        return Self.tables[language]?.localizedString(forKey: key, value: english, table: nil) ?? english
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: self[key], arguments: arguments)
    }

    /// Each language's `.lproj`, by its name in `TaoolUpdates.languages`.
    static let tables: [String: Bundle] = {
        var tables: [String: Bundle] = [:]
        for name in Bundle.module.localizations {
            let normalized = UpdateLanguage.normalized(name)
            guard let language = TaoolUpdates.languages.first(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }),
                  let path = Bundle.module.path(forResource: name, ofType: "lproj"), let bundle = Bundle(path: path)
            else { continue }
            tables[language] = bundle
        }
        return tables
    }()
}

/// Which language the prompts speak.
enum UpdateLanguage {
    /// The closest of `candidates` to `identifier`: the same one, else the same language and
    /// script in the nearest region ("es-AR" → "es-MX", "pt" → "pt-BR"). Never another script:
    /// "zh-HK" is never "zh-Hans". Nil when none is in that language.
    static func closest(to identifier: String, in candidates: [String]) -> String? {
        let wanted = normalized(identifier)
        if let same = candidates.first(where: { normalized($0).caseInsensitiveCompare(wanted) == .orderedSame }) { return same }

        let target = Locale.Language(identifier: Locale.Language(identifier: wanted).maximalIdentifier)
        let regions = containingRegions(target.region)
        var best: (candidate: String, distance: Int, hasRegion: Bool)?
        for candidate in candidates {
            let given = Locale.Language(identifier: normalized(candidate))
            let language = Locale.Language(identifier: given.maximalIdentifier)
            guard language.languageCode == target.languageCode, language.script == target.script else { continue }
            // How far up the target's regions the nearest one both are in: a country, then its
            // part of the world, then the world.
            let distance = containingRegions(language.region).compactMap { regions.firstIndex(of: $0) }.min() ?? regions.count
            // A tie goes to the language's general form ("fr" over "fr-CA" for Belgium), then the list's order.
            let hasRegion = given.region != nil
            if best.map({ distance < $0.distance || distance == $0.distance && !hasRegion && $0.hasRegion }) ?? true {
                best = (candidate, distance, hasRegion)
            }
        }
        return best?.candidate
    }

    /// Hyphens, and Norwegian as Bokmål: iOS says "nb", some apps' folders "no".
    static func normalized(_ identifier: String) -> String {
        let hyphenated = identifier.replacingOccurrences(of: "_", with: "-")
        let parts = hyphenated.split(separator: "-", maxSplits: 1)
        guard parts.first?.lowercased() == "no" else { return hyphenated }
        return (["nb"] + parts.dropFirst()).joined(separator: "-")
    }

    /// A region and the ones it's in, up to the world. Latin America ("es-419") is in the Americas.
    private static func containingRegions(_ region: Locale.Region?) -> [String] {
        var chain: [String] = []
        var next = region
        while let region = next {
            chain.append(region.identifier)
            next = region.identifier == "419" ? Locale.Region("019") : region.containingRegion
        }
        return chain
    }
}
