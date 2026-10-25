// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import TaoolCore
import Testing
@testable import TaoolUpdates

struct UpdateLanguageTests {
    @Test func theAppsLanguage_notTheDevices() {
        #expect(RunningApp.language(preferred: ["sv", "en"], development: "en") == "sv")
        #expect(RunningApp.language(preferred: ["Base"], development: "de") == "de", "Base is the development language")
        #expect(RunningApp.language(preferred: [], development: nil) == "en")
        #expect(RunningApp.language(preferred: ["Base"], development: "Base") == "en")
        #expect(RunningApp.language(preferred: ["pt_BR"], development: "en") == "pt-BR")
    }

    @Test(arguments: [
        ("de", "de"), ("en-GB", "en"), ("en_US", "en"),
        ("es-ES", "es"), ("es-AR", "es-MX"), ("es-419", "es-MX"), ("es-US", "es-MX"),
        ("pt", "pt-BR"), ("pt-PT", "pt-PT"), ("fr-BE", "fr"), ("fr-CA", "fr-CA"),
        ("zh", "zh-Hans"), ("zh-Hans", "zh-Hans"), ("zh-TW", "zh-Hant"), ("zh-HK", "zh-HK"), ("zh-MO", "zh-Hant"),
        ("no", "nb"), ("nb-NO", "nb"), ("iw", "he"),
    ])
    func closestOfTaoolKitsLanguages(identifier: String, expected: String) {
        #expect(UpdateLanguage.closest(to: identifier, in: TaoolUpdates.languages) == expected)
    }

    @Test func noneInThatLanguage_nil() {
        #expect(UpdateLanguage.closest(to: "is", in: TaoolUpdates.languages) == nil)
        #expect(UpdateLanguage.closest(to: "zh-Hant", in: ["zh-Hans", "en"]) == nil, "never another script")
        #expect(UpdateStrings(language: "is").language == "en", "TaoolKit's own text falls back to English")
    }

    @Test func theLock_winsOverTheApp() {
        #expect(UpdateWording(policy: policy(language: "sv"), appLanguage: "en").language == "sv")
        #expect(UpdateWording(policy: policy(language: nil), appLanguage: "de").language == "de")
        #expect(UpdateWording(policy: nil, appLanguage: "ja").language == "ja")
    }

    private func policy(language: String?) -> UpdatePolicy {
        var policy = UpdatePolicy(appId: 1, minimumVersion: nil, versions: [])
        policy.language = language
        return policy
    }
}

struct UpdateMessageTests {
    private func wording(_ messages: UpdateMessage..., language: String = "en", minimum: String? = nil) -> UpdateWording {
        UpdateWording(language: language, messages: messages, minimumVersion: minimum, appName: "Zip Zap")
    }

    @Test func noMessages_taoolKitsOwn() {
        let text = wording().text(.available, version: "2.0")
        #expect(text == UpdatePromptText(title: "Update Available", message: "Version 2.0 is on the App Store.", button: "Update"))
        #expect(wording().text(.required, version: "2.0").message
                == "This version of Zip Zap is no longer supported. Update to version 2.0 to keep using it.")
        #expect(wording().text(.required, version: nil).message
                == "This version of Zip Zap is no longer supported. Update it from the App Store to keep using it.")
    }

    @Test func available_theReleasesMessage_thenEveryVersions() {
        let messages = wording(UpdateMessage(kind: "available", texts: ["en": "A new {app} is out."]),
                               UpdateMessage(kind: "available", version: "2.0", texts: ["en": "{version} adds live timing to {app}."]))
        #expect(messages.text(.available, version: "2.0.0").message == "2.0.0 adds live timing to Zip Zap.", "2.0.0 is 2.0")
        #expect(messages.text(.available, version: "2.1").message == "A new Zip Zap is out.")
        #expect(messages.text(.available, version: "2.0").title == "Update Available", "titles stay TaoolKit's")
    }

    @Test func required_theMinimumsMessage_thenEveryVersions() {
        let every = UpdateMessage(kind: "required", texts: ["en": "Please update {app} to {version}."])
        let aboutMinimum = UpdateMessage(kind: "required", version: "1.8", texts: ["en": "1.8 fixes a bug that could lose your data."])
        #expect(wording(every, aboutMinimum, minimum: "1.8").text(.required, version: "1.9").message == "1.8 fixes a bug that could lose your data.")
        #expect(wording(every, aboutMinimum, minimum: "1.9").text(.required, version: "1.9").message == "Please update Zip Zap to 1.9.",
                "a message about an earlier minimum no longer applies")
        #expect(wording(every, aboutMinimum, minimum: "1.8").text(.available, version: "1.9").message == "Version 1.9 is on the App Store.",
                "a required message never shows on the banner")
    }

    @Test func versionPlaceholder_withNoVersion_theDefault() {
        let messages = wording(UpdateMessage(kind: "required", texts: ["en": "Update to {version} now."]), minimum: "1.8")
        #expect(messages.text(.required, version: nil).message
                == "This version of Zip Zap is no longer supported. Update it from the App Store to keep using it.")
        let noPlaceholder = wording(UpdateMessage(kind: "required", texts: ["en": "Older versions can't sync anymore."]))
        #expect(noPlaceholder.text(.required, version: nil).message == "Older versions can't sync anymore.")
    }

    @Test func notInThisLanguage_theDefaultInIt() {
        let english = UpdateMessage(kind: "available", texts: ["en": "A new version is out."])
        #expect(wording(english, language: "de").text(.available, version: "2.0").message == "Version 2.0 ist im App Store verfügbar.")
        // The version's message lacks German, the one for every version has it.
        let german = UpdateMessage(kind: "available", texts: ["de": "Eine neue Version ist da.", "en": "A new version is out."])
        let versionEnglishOnly = UpdateMessage(kind: "available", version: "2.0", texts: ["en": "2.0 is out."])
        #expect(wording(german, versionEnglishOnly, language: "de").text(.available, version: "2.0").message == "Eine neue Version ist da.")
        #expect(wording(german, language: "de-AT").text(.available, version: "2.0").message == "Eine neue Version ist da.", "region ignored")
    }

    @Test func aLanguageTaoolKitLacks_theDevelopersMessageStillMatches() {
        let icelandic = UpdateMessage(kind: "available", texts: ["is": "Ný útgáfa er komin."])
        #expect(wording(icelandic, language: "is").text(.available, version: "2.0").message == "Ný útgáfa er komin.")
        #expect(wording(icelandic, language: "is").text(.available, version: "2.0").title == "Update Available", "English where TaoolKit has none")
    }

    @Test func blankOrUnknownKinds_ignored() {
        #expect(wording(UpdateMessage(kind: "available", texts: ["en": "  "])).text(.available, version: "2.0").message
                == "Version 2.0 is on the App Store.")
        #expect(wording(UpdateMessage(kind: "celebrate", texts: ["en": "Hooray"])).text(.available, version: "2.0").message
                == "Version 2.0 is on the App Store.")
    }

    @Test func taoolKitsTextInEachLanguage() {
        func text(_ kind: UpdateMessageKind, _ language: String) -> UpdatePromptText {
            UpdateWording(language: language, appName: "Zip Zap").text(kind, version: "2.0")
        }
        let german = text(.required, "de-CH")
        #expect(german.title == "Update erforderlich")
        #expect(german.message.contains("Zip Zap") && german.message.contains("2.0"))
        #expect(german.button == "Aktualisieren")
        #expect(text(.available, "sv").message == "Version 2.0 finns i App Store.")
        #expect(text(.available, "is").title == "Update Available")
    }

    @Test func unsupported_alwaysTaoolKits() {
        let text = wording(UpdateMessage(kind: "required", texts: ["sv": "Uppdatera nu."]), language: "sv")
            .unsupportedText(requiredOSVersion: "26.0", osName: "iOS")
        #expect(text.title == "Uppdatering inte tillgänglig")
        #expect(text.message.contains("26.0") && text.message.contains("Zip Zap"))
        #expect(wording().unsupportedText(requiredOSVersion: nil, osName: "iOS").message == "This version of Zip Zap is no longer supported.")
    }

    @MainActor @Test func statusText_fromTheLastAnswer() throws {
        let release = AppRelease(version: "2.0", appStoreURL: AppRelease.appStoreURL(appId: 1))
        let json = Data(#"{"appId":1,"versions":[],"language":"fr","messages":[{"kind":"available","texts":{"fr":"Nouvelle version."}}]}"#.utf8)
        UpdateState.shared.show(try Kit.decoder.decode(UpdatePolicy.self, from: json))
        defer { UpdateState.shared.show(nil) }
        #expect(UpdateStatus.available(release).text?.message == "Nouvelle version.")
        #expect(UpdateStatus.required(release).text?.title == "Mise à jour requise")
        #expect(UpdateStatus.current.text == nil)
        #expect(UpdateStatus.unsupported(requiredOSVersion: nil).text?.title == "Mise à jour indisponible")
    }

    @Test func decodesTheLockAndMessages() throws {
        let json = Data("""
            {"appId":1,"minimumVersion":"1.8","versions":[],"language":"sv",
             "messages":[{"kind":"required","version":"1.8","texts":{"sv":"1.8 rättar ett fel."}},
                         {"kind":"available","texts":{"sv":"Nytt i {app}."}}]}
            """.utf8)
        let policy = try Kit.decoder.decode(UpdatePolicy.self, from: json)
        #expect(policy.language == "sv")
        #expect(policy.messages?.count == 2)
        #expect(policy.messages?.first?.version == "1.8")
        #expect(policy.messages?.last?.version == nil)
        // An answer without them decodes too.
        let bare = try Kit.decoder.decode(UpdatePolicy.self, from: Data(#"{"appId":1,"versions":[]}"#.utf8))
        #expect(bare.language == nil && bare.messages == nil && bare.whatsNew == nil)
        // And what's kept round-trips.
        let reencoded = try Kit.decoder.decode(UpdatePolicy.self, from: Kit.encoder.encode(policy))
        #expect(reencoded == policy)
    }
}

struct UpdateStringsTests {
    /// Every language has every one of English's strings, with the same arguments.
    @Test func everyLanguage_hasEveryString() throws {
        let english = try strings("en")
        #expect(english.count == 13)
        for language in TaoolUpdates.languages {
            let table = try strings(language)
            #expect(Set(table.keys) == Set(english.keys), "\(language)")
            for (key, value) in english {
                #expect(arguments(table[key] ?? "") == arguments(value), "\(language): \(key)")
            }
        }
    }

    @Test func eachLanguageIsItsOwn() throws {
        #expect(UpdateStrings(language: "de")["banner.title"] == "Update verfügbar")
        #expect(UpdateStrings(language: "pt-PT").format("unsupported.messageIOS", "Zip Zap", "iOS", "26.0").contains("Definições"))
        #expect(UpdateStrings(language: "pt-BR").format("unsupported.messageIOS", "Zip Zap", "iOS", "26.0").contains("Ajustes"))
        #expect(UpdateStrings(language: "zh-HK")["banner.notNow"] != UpdateStrings(language: "zh-Hant")["banner.notNow"])
    }

    private func strings(_ language: String) throws -> [String: String] {
        let table = try #require(UpdateStrings.tables[language], "\(language) has no .lproj")
        let url = try #require(table.url(forResource: "Localizable", withExtension: "strings"))
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    /// The arguments a format string uses, by position: "%@" is 1, "%2$@" is 2.
    private func arguments(_ format: String) -> Set<Int> {
        var positions = Set<Int>()
        var next = 1
        for match in format.matches(of: /%(?:(\d+)\$)?@/) {
            if let position = match.1.flatMap({ Int($0) }) {
                positions.insert(position)
            } else {
                positions.insert(next)
                next += 1
            }
        }
        return positions
    }
}
