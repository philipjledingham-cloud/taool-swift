// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import TaoolCore
import Testing
@testable import TaoolAnalytics
@testable import TaoolFlags

/// Answers requests from a closure. One test at a time uses it (the suite that does is serialized).
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: (URLRequest) -> (Int, Data)? = { _ in nil }
    nonisolated(unsafe) static var requests: [URLRequest] = []
    /// The answers' headers.
    nonisolated(unsafe) static var headers: [String: String]?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let (status, data) = Self.respond(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct FlagBucketTests {
    /// taool's server works out the same places, so the users it shows as in a percentage are the ones the device puts
    /// in it.
    @Test func theSamePlacesAsTaool() {
        #expect(FlagRules.bucket(salt: "k3j9x2m7q1w8e5r4", id: "704000000000000001") == 9799)
        #expect(FlagRules.bucket(salt: "k3j9x2m7q1w8e5r4", id: "704000000000000002") == 2463)
        #expect(FlagRules.bucket(salt: "zz-salt_00000000", id: "7001") == 942)
    }

    @Test func eachFlagItsOwnOrder() {
        #expect(FlagRules.bucket(salt: "a1", id: "7001") != FlagRules.bucket(salt: "a2", id: "7001"))
        #expect((0..<1_000).allSatisfy { (0..<10_000).contains(FlagRules.bucket(salt: "salt", id: "\($0)")) })
    }
}

@Suite struct FlagRuleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A flag as taool sends it: on for half on the App Store, off before 2.4, on for English on an iPad, on in TestFlight.
    let json = #"""
    {"flags":[{"key":"new-sync","salt":"k3j9x2m7q1w8e5r4",
      "rules":[{"when":[{"attribute":"appversion","op":"below","values":["2.4"]}],"serve":{"value":false}},
               {"when":[{"attribute":"language","op":"in","values":["en"]},{"attribute":"device","op":"in","values":["pad"]}],"serve":{"value":true}}],
      "serve":{"value":true,"otherwise":false,"percent":50},"testFlight":{"value":true}},
     {"key":"later","salt":"s","serve":{"value":true},"rules":[{"when":[{"attribute":"moonphase","op":"is","values":["full"]}],"serve":{"value":false}}]}]}
    """#

    var flags: [FlagFile.Flag] { (try? Kit.decoder.decode(FlagFile.self, from: Data(json.utf8)).flags) ?? [] }

    var user: FlagFacts {
        FlagFacts(appTransactionID: "704000000000000001", appVersion: "2.5", osVersion: "27.0", deviceKind: "pad", territory: "SWE", language: "en-GB")
    }

    func value(_ facts: FlagFacts, picked: JSONValue? = nil, flag: Int = 0) -> JSONValue? {
        flags.indices.contains(flag) ? FlagRules.value(of: flags[flag], picked: picked, facts: facts, now: now) : nil
    }

    @Test func inTheOrderTaoolShowsThem() {
        #expect(flags.count == 2 && flags[0].off == nil)
        #expect(value(user) == .bool(true), "en matches en-GB, on an iPad")
        var old = user
        old.appVersion = "2.3.9"
        #expect(value(old) == .bool(false), "the first rule that matches wins")
        old.isTestBuild = true
        #expect(value(old) == .bool(true), "TestFlight's own value before the rules")
        #expect(value(old, picked: .bool(false)) == .bool(false), "the developer's pick before TestFlight's and the rules")
        var phone = user
        phone.deviceKind = "phone"
        // Bucket 9799 isn't in the first half; 2463 is.
        #expect(value(phone) == .bool(false))
        phone.appTransactionID = "704000000000000002"
        #expect(value(phone) == .bool(true))
        phone.appTransactionID = nil
        #expect(value(phone) == .bool(false), "out of every percentage until StoreKit says who this is")
    }

    @Test func turnedOffForEveryoneBeatsEverything() throws {
        var flag = try #require(flags.first)
        flag.off = true
        #expect(FlagRules.value(of: flag, picked: nil, facts: user, now: now) == .bool(false))
        #expect(FlagRules.value(of: flag, picked: .bool(true), facts: user, now: now) == .bool(false), "a user picked on too")
        var tester = user
        tester.isTestBuild = true
        #expect(FlagRules.value(of: flag, picked: nil, facts: tester, now: now) == .bool(false), "TestFlight's own value too")
    }

    @Test func aSignedInUserByTheirIDAsTheServerHashesIt() {
        let half = FlagFile.Flag(key: "half", salt: "k3j9x2m7q1w8e5r4", serve: .init(value: .bool(true), otherwise: .bool(false), percent: 50))
        var signedIn = user
        signedIn.userID = FlagRules.canonical("player-a")
        let byUser = FlagRules.bucket(salt: half.salt, id: "player-a") < 5_000
        #expect(FlagRules.value(of: half, picked: nil, facts: signedIn, now: now) == .bool(byUser), "the user's ID, not the Apple Account's")
        signedIn.appTransactionID = nil
        #expect(FlagRules.value(of: half, picked: nil, facts: signedIn, now: now) == .bool(byUser), "and before StoreKit has said")
        #expect(FlagRules.canonical(" 6F9619FF-8B86-D011-B42D-00C04FC964FF ") == "6f9619ff-8b86-d011-b42d-00c04fc964ff")
        #expect(FlagRules.canonical("6F9619FF8B86D011B42D00C04FC964FF") == "6f9619ff-8b86-d011-b42d-00c04fc964ff", "the 32-digit form too")
        #expect(FlagRules.canonical("{6F9619FF-8B86-D011-B42D-00C04FC964FF}") == "{6F9619FF-8B86-D011-B42D-00C04FC964FF}",
                "braces aren't a form, as on taool's server")
        #expect(FlagRules.canonical("Player-A") == "Player-A", "anything else as it is")
        #expect(FlagRules.canonical("  ") == nil)
    }

    @Test func everyoneOrNoOneNeedsNoIdeaWhoThisIs() {
        var stranger = user
        stranger.appTransactionID = nil
        let done = FlagFile.Flag(key: "done", salt: "s", serve: .init(value: .bool(true), otherwise: .bool(false),
                                                                   steps: [.init(percent: 50, at: now.addingTimeInterval(-7_200)),
                                                                           .init(percent: 100, at: now.addingTimeInterval(-3_600))]))
        #expect(FlagRules.value(of: done, picked: nil, facts: stranger, now: now) == .bool(true), "a finished rollout reaches everyone")
        #expect(FlagRules.value(of: done, picked: nil, facts: stranger, now: now.addingTimeInterval(-5_000)) == .bool(false),
                "at 50% a user StoreKit can't name is out")
        let none = FlagFile.Flag(key: "none", salt: "s", serve: .init(value: .bool(true), otherwise: .bool(false), percent: 0))
        #expect(FlagRules.value(of: none, picked: nil, facts: user, now: now) == .bool(false))
    }

    @Test func aRuleThisVersionCantReadIsPassedOver() {
        #expect(value(user, flag: 1) == .bool(true))
    }

    @Test func stepsClimbAndHoldWhenPaused() {
        let steps = [FlagFile.Step(percent: 1, at: now.addingTimeInterval(-7_200)), FlagFile.Step(percent: 25, at: now.addingTimeInterval(-3_600)),
                     FlagFile.Step(percent: 100, at: now.addingTimeInterval(3_600))]
        var serve = FlagFile.Serve(value: .bool(true), otherwise: .bool(false), steps: steps)
        #expect(FlagRules.percent(of: serve, at: now) == 25)
        #expect(FlagRules.percent(of: serve, at: now.addingTimeInterval(-9_000)) == 0)
        #expect(FlagRules.percent(of: serve, at: now.addingTimeInterval(7_200)) == 100)
        serve.pausedAt = now.addingTimeInterval(-5_400)
        #expect(FlagRules.percent(of: serve, at: now.addingTimeInterval(7_200)) == 1, "held where it was paused")
    }

    @Test func conditions() {
        func holds(_ attribute: String, _ op: String, _ values: [String], _ facts: FlagFacts) -> Bool {
            FlagRules.matches([.init(attribute: attribute, op: op, values: values)], facts)
        }
        var facts = user
        facts.downloadedAt = now
        facts.products = ["pro.yearly"]
        #expect(holds("appversion", "atleast", ["2.5.0"], facts) && !holds("appversion", "below", ["2.5"], facts))
        #expect(holds("osversion", "atleast", ["26.4"], facts) && holds("osversion", "below", ["27.0.1"], facts))
        #expect(holds("country", "in", ["swe", "NOR"], facts) && !holds("country", "notin", ["SWE"], facts))
        #expect(holds("language", "notin", ["e"], facts), "a language is its whole code, or that and a region")
        #expect(holds("downloaded", "onorafter", ["2027-01-15"], facts) && holds("downloaded", "before", ["2027-01-16"], facts))
        #expect(holds("subscribed", "is", [], facts) && holds("subscribed", "isnot", ["pro.monthly"], facts))
        facts.territory = nil
        #expect(!holds("country", "notin", ["SWE"], facts), "never in or out of a list while the device doesn't know")
    }

    @Test func anOSVersionForEachKindOfDevice() {
        func holds(_ op: String, _ values: [String], _ facts: FlagFacts) -> Bool {
            FlagRules.matches([.init(attribute: "osversion", op: op, values: values)], facts)
        }
        // An iPad on 27.0.
        var facts = user
        #expect(holds("atleast", ["26.0"], facts) && !holds("below", ["26.0"], facts), "any Apple OS")
        #expect(holds("atleast", ["phone:28.0", "pad:18.0"], facts) && !holds("below", ["phone:28.0", "pad:18.0"], facts), "the iPad's own")
        #expect(!holds("atleast", ["pad:28.0", "26.0"], facts), "its own over any Apple OS's, as Swift's anyAppleOS")
        #expect(!holds("atleast", ["phone:18.0"], facts) && !holds("below", ["phone:30.0"], facts), "neither on a device it doesn't name")
        facts.deviceKind = nil
        #expect(holds("atleast", ["pad:28.0", "26.0"], facts), "any Apple OS's while the device doesn't know its kind")
    }
}

@Suite(.serialized) struct FlagStoreTests {
    init() {
        StubProtocol.requests = []
        StubProtocol.respond = { _ in nil }
        StubProtocol.headers = nil
    }

    /// A store as a launch has it, starting from `kept` in `folder`, with a check-in of its own that never checks in.
    @MainActor private func store(kept: FlagState? = nil, in folder: URL? = nil, facts: FlagFacts = FlagFacts(appTransactionID: "7001"),
                                  read: (@MainActor () -> FlagFacts)? = nil) -> (FlagStore, CheckIns) {
        let folder = folder ?? FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())")
        let file = StateFile<FlagState>(url: folder.appending(path: "flags.json"))
        if let kept { file.write(kept) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let checkIns = CheckIns(file: StateFile(url: folder.appending(path: "check-in.json")))
        let store = FlagStore(file: file, session: URLSession(configuration: config), baseURL: URL(string: "https://api.test")!,
                              checkIns: checkIns, readFacts: { read?() ?? facts })
        checkIns.start(.flags, key: "taool_key", level: .automatic, bundleID: "com.example.app")
        checkIns.attach(flags: store)
        return (store, checkIns)
    }

    @Test @MainActor func offUntilTaoolHasSaidThenTheLastValuesHeard() async throws {
        let (empty, _) = store()
        #expect(!empty.isOn("new-sync"), "no default in code: off until taool has said")

        StubProtocol.respond = { _ in (200, Data(#"{"flags":[{"key":"new-sync","salt":"s","serve":{"value":true}}]}"#.utf8)) }
        StubProtocol.headers = ["ETag": #""v1""#]
        await empty.becameActive()
        #expect(empty.isOn("new-sync") && !empty.isOn("unknown"))
        let request = try #require(StubProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.test/v1/flags/com.example.app?key=taool_key")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil, "the launch's first ask is whole")

        // Asked again only once a minute has passed, until taool says otherwise, with the version it has: unchanged, the
        // values stay.
        await empty.becameActive(now: .now.addingTimeInterval(30))
        #expect(StubProtocol.requests.count == 1)
        StubProtocol.respond = { _ in (304, Data()) }
        await empty.becameActive(now: .now.addingTimeInterval(70))
        #expect(StubProtocol.requests.count == 2 && StubProtocol.requests[1].value(forHTTPHeaderField: "If-None-Match") == #""v1""#)
        #expect(empty.isOn("new-sync"))

        // taool's interval, from the check-in: 15 minutes here. Changed, the new values apply then.
        empty.checkedIn(flags: nil, userFlags: nil, interval: 900, userID: nil, transition: false)
        StubProtocol.respond = { _ in (200, Data(#"{"flags":[{"key":"new-sync","salt":"s","serve":{"value":false}}]}"#.utf8)) }
        await empty.becameActive(now: .now.addingTimeInterval(200))
        #expect(StubProtocol.requests.count == 2)
        await empty.becameActive(now: .now.addingTimeInterval(1_000))
        #expect(StubProtocol.requests.count == 3 && !empty.isOn("new-sync"))

        // Offline, the last values stay.
        StubProtocol.respond = { _ in nil }
        await empty.becameActive(now: .now.addingTimeInterval(2_000))
        #expect(StubProtocol.requests.count == 4 && !empty.isOn("new-sync"))
    }

    @Test @MainActor func picksComeWithTheCheckIn() {
        var kept = FlagState()
        kept.file = FlagFile(flags: [.init(key: "new-sync", salt: "s", serve: .init(value: .bool(false)))])
        let (store, _) = store(kept: kept)
        #expect(!store.isOn("new-sync"), "what was kept, at launch")
        store.checkedIn(flags: [FlagOverride(key: "new-sync", value: .bool(true)), FlagOverride(key: "made-since", value: .bool(true))],
                        userFlags: nil, interval: nil, userID: nil, transition: true)
        #expect(store.isOn("new-sync") && store.isOn("made-since"), "a pick for a flag made since the flags were sent counts too")
        store.checkedIn(flags: nil, userFlags: nil, interval: nil, userID: nil, transition: true)
        #expect(store.isOn("new-sync"), "taool didn't look: the picks stay")
        store.checkedIn(flags: [], userFlags: nil, interval: nil, userID: nil, transition: true)
        #expect(!store.isOn("new-sync"), "none any more")
    }

    @Test @MainActor func eachUsersPicksTheirOwnOfflineToo() async {
        var kept = FlagState()
        kept.file = FlagFile(flags: [.init(key: "beta", salt: "s", serve: .init(value: .bool(false)))])
        let (store, checkIns) = store(kept: kept)
        func signIn(_ userID: String) async {
            checkIns.start(.flags, key: "taool_key", level: .automatic, userID: userID, bundleID: nil)
            await Task.yield()
        }
        await signIn("player-a")
        store.checkedIn(flags: [], userFlags: [FlagOverride(key: "beta", value: .bool(true))], interval: nil, userID: "player-a", transition: true)
        #expect(store.isOn("beta"))
        // Player B signs in with taool out of reach: A's pick stops at once.
        await signIn("player-b")
        #expect(!store.isOn("beta"), "another user's picks never apply")
        // A again, still offline: theirs are back.
        await signIn("player-a")
        #expect(store.isOn("beta"))
    }

    @Test @MainActor func theSavedUsersPicksAtLaunch() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())")
        var signedIn = CheckInState()
        signedIn.userID = "player-a"
        StateFile<CheckInState>(url: folder.appending(path: "check-in.json")).write(signedIn)
        var kept = FlagState()
        kept.file = FlagFile(flags: [.init(key: "beta", salt: "s", serve: .init(value: .bool(false)))])
        kept.userPicks = [.init(userID: "player-a", picks: [FlagOverride(key: "beta", value: .bool(true))])]
        let (store, _) = store(kept: kept, in: folder)
        #expect(store.isOn("beta"))
    }

    @Test @MainActor func valuesChangeOnlyAsTheAppComesToTheForeground() async {
        let now = Date()
        var kept = FlagState()
        kept.file = FlagFile(flags: [.init(key: "rollout", salt: "s", serve: .init(value: .bool(true), otherwise: .bool(false),
                                                                                   steps: [.init(percent: 100, at: now.addingTimeInterval(60))]))])
        let (store, _) = store(kept: kept)
        await store.becameActive(now: now)
        #expect(!store.isOn("rollout"))
        // A purchase's answer later on changes nothing on screen, nor does the rollout's step reached since.
        store.checkedIn(flags: [FlagOverride(key: "picked", value: .bool(true))], userFlags: nil, interval: nil, userID: nil, transition: false)
        #expect(!store.isOn("picked") && !store.isOn("rollout"))
        await store.becameActive(now: now.addingTimeInterval(120))
        #expect(store.isOn("picked") && store.isOn("rollout"))
    }

    @Test @MainActor func theRunningAppFromTheFirstScreen() {
        var kept = FlagState()
        kept.file = FlagFile(flags: [.init(key: "old", salt: "s", rules: [.init(when: [.init(attribute: "appversion", op: "below", values: ["0.0.2"])],
                                                                                serve: .init(value: .bool(true)))],
                                           serve: .init(value: .bool(false)))])
        kept.facts.appVersion = "0.0.1"
        let (store, _) = store(kept: kept)
        #expect(!store.isOn("old"), "the version last launched isn't kept: an update's applies before the app first comes to the foreground")
    }

    @Test @MainActor func subscribedAsTheAppGivesAccessGrantsToo() async {
        StubProtocol.respond = { _ in
            (200, Data(#"{"flags":[{"key":"pro","salt":"s","rules":[{"when":[{"attribute":"subscribed","op":"is","values":["pro.yearly"]}],"serve":{"value":true}}],"serve":{"value":false}}]}"#.utf8))
        }
        let (store, checkIns) = store()
        let purchases = Access(["pro.yearly"])
        checkIns.attach(purchases)
        await store.becameActive()
        #expect(store.isOn("pro"), "what TaoolPurchases gives access to, a grant of taool's say")
        purchases.accessProducts = []
        store.userChanged()
        #expect(!store.isOn("pro"), "another user signed in: what the app gives them, at once")
    }

    @Test @MainActor func aFailedStoreKitReadKeepsWhoThisIs() async {
        var answers = [FlagFacts(appTransactionID: "704000000000000002", isTestBuild: true, territory: "SWE"), FlagFacts()]
        StubProtocol.respond = { _ in
            (200, Data(#"{"flags":[{"key":"half","salt":"k3j9x2m7q1w8e5r4","serve":{"value":true,"otherwise":false,"percent":50}}]}"#.utf8))
        }
        let (store, _) = store(read: { answers.isEmpty ? FlagFacts() : answers.removeFirst() })
        await store.becameActive()
        #expect(store.isOn("half"), "bucket 2463 is in the first half")
        // A minute on, StoreKit doesn't answer: the user stays who they were, in their half.
        await store.becameActive(now: .now.addingTimeInterval(120))
        #expect(store.isOn("half"))
    }

    @Test func whatsKeptOfWhoThisIsWhenStoreKitDoesntAnswer() {
        let tester = FlagFacts(appTransactionID: "7001", isTestBuild: true, territory: "SWE")
        let kept = FlagFacts().keepingKnown(from: tester)
        #expect(kept.appTransactionID == "7001" && kept.territory == "SWE")
        #expect(!kept.isTestBuild, "the environment is the build's: the App Store's install of TestFlight's build isn't a test build")
    }

    @Test @MainActor func typedFlagsGiveTheirValuesTheCodesDefaultUntilThen() async {
        StubProtocol.respond = { _ in
            (200, Data(#"""
            {"flags":[{"key":"headline","salt":"s","serve":{"value":"Try a week free"},"default":"Unlock Pro"},
              {"key":"trial-days","salt":"s","off":true,"serve":{"value":14},"default":7},
              {"key":"plans","salt":"s","serve":{"value":[{"id":"pro","months":12}]},"default":[]}]}
            """#.utf8))
        }
        struct Plan: Decodable, Equatable { let id: String; let months: Int }
        let (store, _) = store()
        #expect(store.value("headline") == nil, "nothing heard yet")
        await store.becameActive()
        #expect(store.value("headline") == .string("Try a week free"))
        #expect(store.value("trial-days") == .number(7), "turned off, its default")
        // The public readers go through the shared store, so check their decoding on the values themselves.
        let data = try? JSONEncoder().encode(store.value("plans"))
        #expect(data.flatMap { try? JSONDecoder().decode([Plan].self, from: $0) } == [Plan(id: "pro", months: 12)])
    }

    @Test @MainActor func forcedInDebug() {
        let (store, _) = store()
        store.force("new-sync", true)
        #expect(store.isOn("new-sync"))
        store.force("new-sync", false)
        #expect(!store.isOn("new-sync") && store.value("new-sync") == .bool(false))
    }
}

/// TaoolPurchases' side, as far as a subscribed rule asks it: what gives access.
@MainActor
private final class Access: CheckInContributor {
    var accessProducts: Set<String>?

    init(_ products: Set<String>) { accessProducts = products }

    var pendingReason: CheckInReason? { nil }
    func prepare(now: Date, userChanged: Bool) async {}
    func nextPart() -> (part: CheckInReport.Purchases, sent: [String]) { (.init(transactions: nil, renewals: nil), []) }
    func checkedIn(_ outcome: CheckInOutcome, sent: [String]) {}
    func userChanged() {}
}
