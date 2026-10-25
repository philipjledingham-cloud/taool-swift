// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import StoreKit
import TaoolCore

/// What the device says about itself with a check-in, by the app's analytics level: nothing at
/// minimal; the app's version and build, TaoolKit's version, the platform, the App Store country
/// (StoreKit's storefront, never the IP), the language the app runs in, the language the user
/// asked for in Settings and the device's region at standard; and with expanded analytics, the OS
/// version, the kind of device and its hardware model ("iPhone17,1"), and the opens counted on the
/// device, with the UTC days they were on.
/// Never the device's name, IDFA, IDFV, an install ID or anything else that tells two devices apart.
package struct DeviceFacts: Encodable, Sendable, Equatable {
    // Standard: with every check-in, unless the app's code holds analytics at minimal.
    var appVersion: String?
    var build: String?
    var kitVersion: String?
    var platform: String?
    var storefront: String?
    var language: String?
    var deviceLanguage: String?
    var region: String?

    // Expanded: only while expanded analytics are on, from the developer's switch in the taool app or their code.
    var osVersion: String?
    var deviceKind: String?
    var model: String?
    var opens: Int?
    var lastOpenedAt: Date?
    var openedDays: [String]?

    /// The facts for `level`; nil at minimal.
    @MainActor
    static func collect(_ level: TaoolAnalytics.Level, opens: Int, lastOpenedAt: Date?, openedDays: [String] = []) async -> DeviceFacts? {
        guard level != .minimal else { return nil }
        var facts = DeviceFacts(appVersion: RunningApp.version, build: RunningApp.build, kitVersion: Kit.version, platform: RunningApp.platform,
                                storefront: await storefront(), language: RunningApp.language, deviceLanguage: deviceLanguage,
                                region: Locale.current.region?.identifier)
        guard level == .expanded else { return facts }
        facts.osVersion = RunningApp.osVersion
        facts.deviceKind = RunningApp.deviceKind
        facts.model = model
        facts.opens = opens > 0 ? opens : nil
        facts.lastOpenedAt = lastOpenedAt
        facts.openedDays = openedDays.isEmpty ? nil : openedDays
        return facts
    }

    /// The language the user asked for in Settings, the first of their preferred languages, "sv", or with its script
    /// "zh-Hant": what they'd read the app in, which the app may not have. `language` is what it shows them. Never a
    /// region, which iOS adds from the device's ("en-SE" for English in Sweden), so one language reads alike everywhere.
    package static var deviceLanguage: String? {
        Locale.preferredLanguages.first.flatMap(language(preferred:))
    }

    /// The language part of a preferred language, and its script only where it names one ("zh-Hant-TW" is "zh-Hant",
    /// "sv-SE" is "sv").
    static func language(preferred identifier: String) -> String? {
        let components = Locale.Language.Components(identifier: identifier)
        guard let code = components.languageCode?.identifier else { return nil }
        return components.script.map { "\(code)-\($0.identifier)" } ?? code
    }

    /// The App Store country, as StoreKit names it ("SWE"), which TaoolFlags' rules compare too.
    package static func storefront() async -> String? { await Storefront.current?.countryCode }

    /// The hardware model, "iPhone17,1" or "Mac16,1" (the simulated one in the simulator); nil if it can't be read. A Mac's
    /// is `hw.model`, Mac Catalyst's and an iPad app's on a Mac too, where `hw.machine` is only "arm64".
    static let model: String? = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #if os(macOS)
        let name = "hw.model"
        #else
        let name = ProcessInfo.processInfo.isMacCatalystApp ? "hw.model" : "hw.machine"
        #endif
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let model = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return model.isEmpty ? nil : model
    }()
}
