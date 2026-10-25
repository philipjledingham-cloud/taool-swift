// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import TaoolAnalytics
import TaoolCore

/// The app's flags as taool sends them, each one's value worked out on the device (`FlagRules.value`).
struct FlagFile: Codable, Sendable, Equatable {
    var flags: [Flag]

    /// Whether a rule asks what the user has bought, which only then is read from StoreKit.
    var asksForProducts: Bool {
        flags.contains { $0.rules?.contains { $0.when.contains { $0.attribute == "subscribed" } } ?? false }
    }

    struct Flag: Codable, Sendable, Equatable {
        let key: String
        /// What a user's place in the flag's percentages is worked out with, the same on every device.
        let salt: String
        /// Turned off for everyone in the taool app: its default, whatever else says, the users picked and TestFlight included.
        var off: Bool?
        var rules: [Rule]?
        /// The App Store's value, for everyone no rule picks.
        let serve: Serve
        /// Its value in TestFlight and development builds; nil for the App Store's.
        var testFlight: Serve?
        /// What it gives turned off, and a percentage's others: false for a flag that's on or off, else the developer's.
        var defaultValue: JSONValue?

        private enum CodingKeys: String, CodingKey {
            case key, salt, off, rules, serve, testFlight
            case defaultValue = "default"
        }
    }

    /// A value for everyone; with `percent`, `value` for that share of users and `otherwise` for the rest; with `steps`, a
    /// rollout climbing on its own, each step's percentage from its time, held at `pausedAt`.
    struct Serve: Codable, Sendable, Equatable {
        let value: JSONValue
        var otherwise: JSONValue?
        var percent: Int?
        var steps: [Step]?
        var pausedAt: Date?
    }

    struct Step: Codable, Sendable, Equatable {
        let percent: Int
        let at: Date
    }

    /// When all its conditions hold, its own value.
    struct Rule: Codable, Sendable, Equatable {
        let when: [Condition]
        let serve: Serve
    }

    /// What a condition compares: an attribute or operator this version doesn't know never holds, so a rule from a newer
    /// taool is passed over rather than guessed at.
    struct Condition: Codable, Sendable, Equatable {
        let attribute: String
        let op: String
        let values: [String]
    }
}

/// What the device knows about itself for its flags' rules: read where it runs, never sent for them.
struct FlagFacts: Codable, Sendable, Equatable {
    /// StoreKit's appTransactionID: the same for this Apple Account on every device and after a reinstall.
    var appTransactionID: String?
    /// The app's own ID for whoever's signed in (`FlagRules.canonical`), which a percentage goes by when there is one, as a
    /// server does; never kept, set from who's signed in as the values are worked out.
    var userID: String?
    /// A TestFlight or development build, as StoreKit says.
    var isTestBuild = false
    var appVersion: String?
    var osVersion: String?
    /// "phone", "pad", "mac", "watch", "vision" or "tv", whose OS an OS version rule can name.
    var deviceKind: String?
    /// The App Store country, as StoreKit names it ("SWE").
    var territory: String?
    /// The language the app runs in ("en", "pt-BR").
    var language: String?
    /// When this Apple Account first downloaded the app; App Store builds only (`AppTransactionFacts.downloadedAt`), so a
    /// new users rule matches no one in TestFlight.
    var downloadedAt: Date?
    /// The products that give access now (`FlagStore.products`).
    var products: Set<String> = []

    /// What's kept on the device: what StoreKit says, which takes a moment at launch or may not come. Never the user ID,
    /// which is whoever's signed in now, nor the running app's version, OS, kind of device and language, read as it
    /// launches (`readRunningApp`), so an update's version applies from the first screen.
    private enum CodingKeys: String, CodingKey {
        case appTransactionID, isTestBuild, territory, downloadedAt, products
    }

    /// What was just read, with what's known from before where StoreKit didn't answer (offline, or before it can say):
    /// the Apple Account, with its download date, and the storefront. Never forgotten for a read that failed, which would
    /// take the user out of every percentage until the next. Never the environment, which is the build's: the App Store's
    /// install of the build TestFlight had isn't TestFlight.
    func keepingKnown(from previous: FlagFacts) -> FlagFacts {
        var facts = self
        if facts.appTransactionID == nil {
            facts.appTransactionID = previous.appTransactionID
            facts.downloadedAt = previous.downloadedAt
        }
        if facts.territory == nil { facts.territory = previous.territory }
        return facts
    }
}

enum FlagRules {
    /// A flag's percentages are shares of these.
    static let buckets = 10_000

    /// A user's place in a flag's percentages, 0 to 9,999, by the flag's salt, ".", and their ID (the app's user ID, else
    /// the appTransactionID): the same user is in the same place on every device and on the app's server, each flag
    /// orders users its own way, and raising a percentage keeps everyone who was already in.
    static func bucket(salt: String, id: String) -> Int {
        Hash.bucket("\(salt).\(id)", count: buckets)
    }

    /// A value's percentage at `now`: its own, or its rollout's latest step (held where it was paused), 0 before the first.
    static func percent(of serve: FlagFile.Serve, at now: Date) -> Int {
        if let percent = serve.percent { return percent }
        let at = serve.pausedAt.map { min($0, now) } ?? now
        return serve.steps?.last { $0.at <= at }?.percent ?? 0
    }

    /// A flag's value for this user, the first that applies: its default while it's turned off for everyone, which
    /// nothing else overrides; what the developer picked for them; TestFlight's value in a TestFlight or development
    /// build; the first rule that matches; then the App Store's.
    static func value(of flag: FlagFile.Flag, picked: JSONValue?, facts: FlagFacts, now: Date) -> JSONValue {
        let fallback = flag.defaultValue ?? .bool(false)
        if flag.off == true { return fallback }
        if let picked { return picked }
        if facts.isTestBuild, let testFlight = flag.testFlight { return testFlight.value }
        if let rule = flag.rules?.first(where: { matches($0.when, facts) }) {
            return served(rule.serve, salt: flag.salt, fallback: fallback, facts: facts, now: now)
        }
        return served(flag.serve, salt: flag.salt, fallback: fallback, facts: facts, now: now)
    }

    private static func served(_ serve: FlagFile.Serve, salt: String, fallback: JSONValue, facts: FlagFacts, now: Date) -> JSONValue {
        guard serve.percent != nil || serve.steps != nil else { return serve.value }
        let otherwise = serve.otherwise ?? fallback
        let percent = percent(of: serve, at: now)
        // Everyone or no one needs no idea who this is, so a finished rollout reaches users StoreKit can't name too.
        if percent >= 100 { return serve.value }
        if percent <= 0 { return otherwise }
        // The user signed in, as the app's server knows them, else the Apple Account; out of every percentage until there's
        // one, rather than in now and out later.
        guard let user = facts.userID ?? facts.appTransactionID else { return otherwise }
        return bucket(salt: salt, id: user) < percent * (buckets / 100) ? serve.value : otherwise
    }

    static func matches(_ conditions: [FlagFile.Condition], _ facts: FlagFacts) -> Bool {
        conditions.allSatisfy { holds($0, facts) }
    }

    private static func holds(_ condition: FlagFile.Condition, _ facts: FlagFacts) -> Bool {
        let values = condition.values
        switch (condition.attribute, condition.op) {
        case ("appversion", "atleast"), ("appversion", "below"), ("osversion", "atleast"), ("osversion", "below"):
            let (version, wanted) = condition.attribute == "appversion"
                ? (facts.appVersion, values.first)
                : (facts.osVersion, osVersion(for: facts.deviceKind, in: values))
            guard let version, let wanted else { return false }
            let isOlder = Versions.compare(version, wanted) == .orderedAscending
            return condition.op == "atleast" ? !isOlder : isOlder
        case ("device", "in"), ("device", "notin"), ("country", "in"), ("country", "notin"):
            let fact = condition.attribute == "device" ? facts.deviceKind : facts.territory
            return isIn(fact, values, op: condition.op) { $0.caseInsensitiveCompare($1) == .orderedSame }
        case ("language", "in"), ("language", "notin"):
            // "en" is English wherever: "en", "en-GB".
            return isIn(facts.language, values, op: condition.op) { language, value in
                language.caseInsensitiveCompare(value) == .orderedSame || language.lowercased().hasPrefix(value.lowercased() + "-")
            }
        case ("downloaded", "onorafter"), ("downloaded", "before"):
            guard let downloaded = facts.downloadedAt, let day = values.first.flatMap(utcDay) else { return false }
            return condition.op == "onorafter" ? downloaded >= day : downloaded < day
        case ("subscribed", "is"), ("subscribed", "isnot"):
            let has = values.isEmpty ? !facts.products.isEmpty : values.contains(where: facts.products.contains)
            return condition.op == "is" ? has : !has
        default:
            return false
        }
    }

    /// In (or not in, for `notin`) the list; never either while the device doesn't know the fact.
    private static func isIn(_ fact: String?, _ values: [String], op: String, same: (String, String) -> Bool) -> Bool {
        guard let fact else { return false }
        return values.contains { same(fact, $0) } == (op == "in")
    }

    /// A user ID as taool's server writes it, so both hash the same text: trimmed, and a UUID lowercase with its dashes,
    /// whatever form the app passed it in; nil for none.
    static func canonical(_ userID: String?) -> String? {
        guard let id = Kit.userID(userID) else { return nil }
        return Kit.uuid(id).map { $0.uuidString.lowercased() } ?? id
    }

    /// The version an OS version rule asks of a device of this kind: its own kind's where the rule names one ("pad:18.0",
    /// iPadOS 18), else any Apple OS's ("26.0", 26 or later), as a platform's own wins over Swift's `anyAppleOS`; nil when
    /// it names neither.
    static func osVersion(for kind: String?, in values: [String]) -> String? {
        var any: String?
        for value in values {
            let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 1 { any = value } else if String(parts[0]) == kind { return String(parts[1]) }
        }
        return any
    }

    /// The start of a UTC day written "2026-10-15".
    private static func utcDay(_ text: String) -> Date? {
        try? Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().parse(text)
    }
}
