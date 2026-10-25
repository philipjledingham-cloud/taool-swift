// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import TaoolCore
import Testing
@testable import TaoolAnalytics

/// Answers requests from a closure. One test at a time uses it (the suite that does is serialized).
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: (URLRequest) -> (Int, Data)? = { _ in nil }
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        // URLProtocol sees an upload's body as a stream.
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = data
        }
        Self.requests.append(request)
        guard let (status, data) = Self.respond(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// TaoolPurchases' side, as a test sets it up: what's queued, and what it was asked.
@MainActor
final class FakePurchases: CheckInContributor {
    var queued: [String] = []
    var outcomes: [CheckInOutcome] = []
    /// Each `prepare`'s `userChanged`.
    var prepared: [Bool] = []
    var accessProducts: Set<String>?

    var pendingReason: CheckInReason? { queued.isEmpty ? nil : .purchase }
    func prepare(now: Date, userChanged: Bool) async { prepared.append(userChanged) }

    func nextPart() -> (part: CheckInReport.Purchases, sent: [String]) {
        (.init(transactions: queued.isEmpty ? nil : queued, renewals: nil), queued)
    }

    func checkedIn(_ outcome: CheckInOutcome, sent: [String]) {
        outcomes.append(outcome)
        queued.removeAll { sent.contains($0) }
    }

    func userChanged() {}
}

/// TaoolFlags' side, as a test sets it up: what came back.
@MainActor
final class FakeFlags: FlagsCheckInListener {
    var answers: [(flags: [FlagOverride]?, userFlags: [FlagOverride]?, interval: Int?, userID: String?, transition: Bool)] = []
    var foregrounds = 0

    func checkedIn(flags: [FlagOverride]?, userFlags: [FlagOverride]?, interval: Int?, userID: String?, transition: Bool) {
        answers.append((flags, userFlags, interval, userID, transition))
    }

    func userChanged() {}

    func becameActive(now: Date) async {
        foregrounds += 1
    }
}

@Suite struct ScheduleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func notOnEveryOpen() {
        var state = CheckInState()
        state.syncInterval = 3_600
        #expect(CheckInSchedule.isDue(state, urgency: .whenDue, now: now), "never checked in")
        state.lastCheckIn = now.addingTimeInterval(-600)
        #expect(!CheckInSchedule.isDue(state, urgency: CheckInReason.launch.urgency, now: now))
        #expect(!CheckInSchedule.isDue(state, urgency: CheckInReason.update.urgency, now: now))
        #expect(CheckInSchedule.isDue(state, urgency: CheckInReason.user.urgency, now: now), "a new user goes at once")
        #expect(CheckInSchedule.isDue(state, urgency: .atOnce, now: now), "news goes at once")
    }

    @Test func aColdLaunchChecksInUnlessTaoolAskedItToWait() {
        var state = CheckInState()
        state.syncInterval = 21_600
        state.lastCheckIn = now.addingTimeInterval(-30)
        #expect(CheckInSchedule.isDue(state, urgency: .coldLaunch, now: now), "restarted the moment after a grant")
        state.launchInterval = 3_600
        #expect(!CheckInSchedule.isDue(state, urgency: .coldLaunch, now: now), "taool asked cold launches to wait")
        #expect(CheckInSchedule.launchWait(answered: nil, interval: 21_600) == 0)
        #expect(CheckInSchedule.launchWait(answered: 99_999, interval: 21_600) == 21_600, "never longer than the interval")
        state.launchInterval = nil
        state.backoffUntil = now.addingTimeInterval(60)
        #expect(!CheckInSchedule.isDue(state, urgency: .coldLaunch, now: now), "a backoff holds it")
    }

    @Test func aBackoffHoldsAllButPurchasesRestoresAndTheAppAsking() {
        var state = CheckInState()
        state.lastCheckIn = now.addingTimeInterval(-30)
        state.backoffUntil = now.addingTimeInterval(60)
        #expect(!CheckInSchedule.isDue(state, urgency: .atOnce, now: now), "something queued waits it out")
        #expect(!CheckInSchedule.isDue(state, urgency: CheckInReason.user.urgency, now: now),
                "a new user waits it out, so a wrong key or taool out of reach never sends at every open")
        #expect(CheckInSchedule.isDue(state, urgency: CheckInReason.purchase.urgency, now: now))
        #expect(CheckInSchedule.isDue(state, urgency: CheckInReason.restore.urgency, now: now))
        #expect(CheckInSchedule.isDue(state, urgency: .now, now: now), "refresh()")
    }

    @Test func taoolsIntervalWithinBounds() {
        #expect(CheckInSchedule.interval(answered: nil) == CheckInSchedule.fallback)
        #expect(CheckInSchedule.interval(answered: 1) == CheckInSchedule.shortest)
        #expect(CheckInSchedule.interval(answered: 99_999_999) == CheckInSchedule.longest)
        #expect(CheckInSchedule.retryDelay(failures: 1) == 60 && CheckInSchedule.retryDelay(failures: 3) == 240)
        #expect(CheckInSchedule.retryDelay(failures: 30) == CheckInSchedule.longestRetry)
    }

    @Test func reasons() {
        #expect(max(CheckInReason.launch, .restore) == .restore && CheckInReason.purchase > .user)
        #expect(CheckInReason.update.urgency == .whenDue && CheckInReason.user.urgency == .atOnce && CheckInReason.purchase.urgency == .now)
        #expect(max(CheckInUrgency.coldLaunch, .whenDue, .atOnce) == .atOnce)
    }
}

@Suite struct LevelTests {
    typealias Level = TaoolAnalytics.Level

    @Test func theCodeHasTheLastWord() {
        #expect(Level.automatic.level(remote: nil) == .standard)
        #expect(Level.automatic.level(remote: "expanded") == .expanded)
        #expect(Level.standard.level(remote: "expanded") == .standard, "a ceiling the taool app can't raise")
        #expect(Level.minimal.level(remote: "expanded") == .minimal)
        #expect(Level.expanded.level(remote: "standard") == .expanded)
    }

    @Test func theMostPrivateTheCodeAsksForHolds() {
        #expect(Level.mostPrivate([]) == .automatic)
        #expect(Level.mostPrivate([.automatic, .automatic]) == .automatic)
        #expect(Level.mostPrivate([.automatic, .expanded]) == .expanded, "automatic asks for nothing")
        #expect(Level.mostPrivate([.expanded, .standard]) == .standard)
        #expect(Level.mostPrivate([.standard, .minimal, .expanded]) == .minimal)
    }

    @Test @MainActor func factsByLevel() async {
        #expect(await DeviceFacts.collect(.minimal, opens: 3, lastOpenedAt: .now) == nil)
        let standard = await DeviceFacts.collect(.standard, opens: 3, lastOpenedAt: .now)
        #expect(standard?.kitVersion == Kit.version && standard?.platform == RunningApp.platform)
        #expect(standard?.opens == nil && standard?.osVersion == nil && standard?.model == nil, "expanded facts stay out")
        #expect(standard?.deviceLanguage == DeviceFacts.deviceLanguage && standard?.language == RunningApp.language,
                "the languages are standard")
        let expanded = await DeviceFacts.collect(.expanded, opens: 3, lastOpenedAt: .now, openedDays: ["2026-10-11"])
        #expect(expanded?.opens == 3 && expanded?.osVersion != nil && expanded?.deviceKind != nil && expanded?.deviceLanguage != nil)
        #expect(expanded?.openedDays == ["2026-10-11"] && standard?.openedDays == nil)
    }

    @Test func theDevicesLanguageWithoutItsRegion() {
        #expect(DeviceFacts.language(preferred: "sv-SE") == "sv" && DeviceFacts.language(preferred: "en-US") == "en")
        #expect(DeviceFacts.language(preferred: "ja-JP") == "ja", "no script it doesn't name")
        #expect(DeviceFacts.language(preferred: "zh-Hant-TW") == "zh-Hant")
    }

    @Test func aClockSetBackHoldsNothing() {
        var state = CheckInState()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        state.lastCheckIn = now.addingTimeInterval(365 * 86_400)
        state.backoffUntil = now.addingTimeInterval(365 * 86_400)
        #expect(CheckInSchedule.isDue(state, urgency: .whenDue, now: now))
        #expect(RefreshSchedule.isDue(askedAt: nil, fetchedAt: now.addingTimeInterval(365 * 86_400), now: now))
    }

    @Test func openedDaysAreUTCDays_OnceEach_TheNewestKept() {
        var state = CheckInState()
        // 23:30 in Los Angeles on the 10th is the 11th in UTC.
        let evening = Date(timeIntervalSince1970: 1_791_700_200)  // 2026-10-11T06:30:00Z
        state.opened(on: evening)
        state.opened(on: evening.addingTimeInterval(3600))
        #expect(state.openedDays == ["2026-10-11"])
        for day in 1...70 { state.opened(on: evening.addingTimeInterval(Double(day) * 86_400)) }
        #expect(state.openedDays.count == CheckInState.maxOpenedDays && state.openedDays.last == "2026-12-20")
    }

    @Test func keptInAFileAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())/check-in.json")
        let file = StateFile<CheckInState>(url: url)
        #expect(file.read() == nil)
        var state = CheckInState()
        state.lastCheckIn = Date(timeIntervalSince1970: 1_800_000_000)
        state.analytics = "expanded"
        state.openedDays = ["2027-01-15"]
        file.write(state)
        #expect(StateFile<CheckInState>(url: url).read() == state)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func aFileFromBeforeAFieldWasAddedStillReads() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())/check-in.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Without `failures` and `opens`, which aren't optional.
        try Data(#"{"lastCheckIn":"2027-01-15T08:00:00Z","analytics":"expanded","openedDays":[]}"#.utf8).write(to: url)
        let read = try #require(StateFile<CheckInState>(url: url).read())
        #expect(read.analytics == "expanded" && read.failures == 0 && read.opens == 0)

        try Data("not json".utf8).write(to: url)
        #expect(StateFile<CheckInState>(url: url).read() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path()), "moved aside, never written over")
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path()))
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

/// The client and the check-in against a stubbed taool, one test at a time.
@Suite(.serialized) struct CheckInNetworkTests {
    init() {
        StubProtocol.requests = []
        StubProtocol.respond = { _ in nil }
    }

    private var client: CheckInClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return CheckInClient(session: URLSession(configuration: config), baseURL: URL(string: "https://api.test")!)
    }

    private let report = CheckInReport(reason: .restore, appTransaction: "app.jws.sig", userId: "player-1", level: 2,
                                       device: DeviceFacts(appVersion: "2.1", kitVersion: "1.0.0", platform: "ios",
                                                           lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                           openedDays: ["2027-01-15"]),
                                       purchases: .init(transactions: ["t.jws.sig"], renewals: nil), flags: .init())

    private static let standardAnswer = Data(#"{"analytics":"standard","syncInterval":86400}"#.utf8)

    /// A check-in of its own, in a file of its own (or `folder`'s, as the next launch would have it), against the stub,
    /// starting from `kept`, as a launch after it would; with `key` nil, never started.
    @MainActor private func checkIns(kept: CheckInState? = nil, in folder: URL? = nil, key: String? = "taool_key",
                                     sessionGrace: Duration = .seconds(3)) -> (CheckIns, URL) {
        let folder = folder ?? FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())")
        let file = StateFile<CheckInState>(url: folder.appending(path: "check-in.json"))
        if let kept { file.write(kept) }
        let checkIns = CheckIns(file: file, client: client, appTransaction: { Self.appTransaction("app.jws.sig", testFlight: false) },
                                sessionGrace: sessionGrace)
        if let key { checkIns.start(.analytics, key: key, level: .automatic, bundleID: "com.example.app") }
        return (checkIns, folder)
    }

    /// StoreKit's record of the app as the check-in reads it.
    private static func appTransaction(_ signed: String, testFlight: Bool) -> AppTransactionFacts {
        AppTransactionFacts(signed: signed, id: "7001", environment: testFlight ? .sandbox : .production, downloadedAt: nil)
    }

    /// What a launch keeps from a check-in `ago` before it.
    private func kept(checkedIn ago: TimeInterval) -> CheckInState {
        var state = CheckInState()
        state.lastCheckIn = .now.addingTimeInterval(-ago)
        state.syncInterval = 21_600
        return state
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
    }

    @Test func sendsTheReportAndReadsTheAnswer() async throws {
        StubProtocol.respond = { _ in
            (200, Data(#"{"analytics":"expanded","syncInterval":21600,"otherUser":["2000000001"],"grants":[{"productId":"pro","expirationDate":"2027-01-15T08:00:00Z"}]}"#.utf8))
        }
        let outcome = await client.send(report, key: "taool_key", bundleID: "com.example.app")
        guard case .answered(let answer) = outcome else { Issue.record("not answered: \(outcome)"); return }
        #expect(answer.analytics == "expanded" && answer.syncInterval == 21600 && answer.otherUser == ["2000000001"])
        #expect(answer.grants?.first?.productId == "pro" && answer.grants?.first?.expirationDate != nil)

        let request = try #require(StubProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.test/v1/sync/com.example.app?key=taool_key")
        let body = try body(request)
        #expect(body["reason"] as? String == "restore" && body["appTransaction"] as? String == "app.jws.sig")
        #expect(body["userId"] as? String == "player-1" && body["level"] as? Int == 2, "who's signed in and the code's level, once")
        #expect(body["transactions"] == nil, "the purchases part is its own")
        let purchases = try #require(body["purchases"] as? [String: Any])
        #expect(purchases["userId"] == nil && (purchases["transactions"] as? [String]) == ["t.jws.sig"])
        #expect((body["flags"] as? [String: Any])?.isEmpty == true, "TaoolFlags' part says only that it's there")
        #expect(purchases["renewals"] == nil)
        let device = try #require(body["device"] as? [String: Any])
        #expect(device["lastOpenedAt"] as? String == "2027-01-15T08:00:00Z", "the one date shape taool reads")
        #expect(device["openedDays"] as? [String] == ["2027-01-15"])
    }

    @Test @MainActor func flagsSendTheirPartAndHearThePicks() async throws {
        StubProtocol.respond = { _ in
            (200, Data(#"{"analytics":"standard","syncInterval":21600,"flags":[{"key":"new-sync","value":true}],"userFlags":[{"key":"new-sync","value":false}],"flagsInterval":300}"#.utf8))
        }
        let (checkIns, _) = checkIns()
        let flags = FakeFlags()
        checkIns.attach(flags: flags)
        checkIns.start(.flags, key: "taool_key", level: .automatic, userID: "player-1", bundleID: nil)
        await checkIns.becameActive()
        let sent = try body(StubProtocol.requests.first)
        #expect(sent["flags"] is [String: Any] && sent["userId"] as? String == "player-1")
        let answer = try #require(flags.answers.first)
        #expect(flags.answers.count == 1 && answer.flags == [FlagOverride(key: "new-sync", value: .bool(true))])
        #expect(answer.userFlags == [FlagOverride(key: "new-sync", value: .bool(false))], "the user's apart")
        #expect(answer.userID == "player-1", "answered for the user it was sent")
        #expect(answer.transition, "the app becoming active's, so its picks apply at once")
        #expect(answer.interval == 300, "how long before the flags are asked for again")
    }

    /// Player A signed in when the app last ran, and taool heard of them.
    private var signedIn: CheckInState {
        var state = kept(checkedIn: 60)
        state.userID = "player-a"
        state.reportedUserID = "player-a"
        return state
    }

    @Test @MainActor func aSessionRestoredLateIsNoSignOut() async throws {
        StubProtocol.respond = { _ in (200, Self.standardAnswer) }
        let (checkIns, folder) = checkIns(kept: signedIn)
        let flags = FakeFlags()
        checkIns.attach(flags: flags)
        // The first render, before the app's session has loaded: no one signed in yet. Then the session.
        checkIns.start(.flags, key: "taool_key", level: .automatic, userID: nil, bundleID: nil)
        #expect(checkIns.userID == "player-a", "the saved user, until the launch has settled")
        checkIns.start(.flags, key: "taool_key", level: .automatic, userID: "player-a", bundleID: nil)
        await checkIns.becameActive()
        await checkIns.checkIn(.launch)
        #expect(StubProtocol.requests.count == 1, "the launch's check-in alone")
        let launch = try body(StubProtocol.requests.first)
        #expect(launch["reason"] as? String == "launch" && launch["userId"] as? String == "player-a")
        #expect(flags.answers.count == 1)
        try FileManager.default.removeItem(at: folder)
    }

    @Test @MainActor func signedOutOnceTheSessionGraceHasPassed() async throws {
        StubProtocol.respond = { _ in (200, Self.standardAnswer) }
        let (checkIns, folder) = checkIns(kept: signedIn, sessionGrace: .milliseconds(500))
        let flags = FakeFlags()
        checkIns.attach(flags: flags)
        checkIns.start(.flags, key: "taool_key", level: .automatic, userID: nil, bundleID: nil)
        await checkIns.becameActive()
        #expect(checkIns.userID == "player-a", "the session may still be loading")
        try await Task.sleep(for: .milliseconds(700))
        await checkIns.checkIn(.launch)
        #expect(checkIns.userID == nil, "still no one once the grace has passed: signed out")
        #expect(StubProtocol.requests.count == 2, "the launch's, then the sign-out's")
        let signOut = try body(StubProtocol.requests.last)
        #expect(signOut["reason"] as? String == "user" && signOut["flags"] is [String: Any] && signOut["userId"] == nil)
        #expect(flags.answers.last?.transition == true, "no one's own picks, at once")
        try FileManager.default.removeItem(at: folder)
    }

    @Test @MainActor func aSignInIsOneCheckIn_HoweverManyProductsHaveTheUser() async throws {
        StubProtocol.respond = { _ in (200, Self.standardAnswer) }
        let (checkIns, folder) = checkIns(kept: kept(checkedIn: 60), sessionGrace: .milliseconds(50))
        let purchases = FakePurchases()
        let flags = FakeFlags()
        checkIns.attach(purchases)
        checkIns.attach(flags: flags)
        await checkIns.becameActive()
        try await Task.sleep(for: .milliseconds(200))
        // Both modifiers given the user, as a render after signing in does.
        checkIns.start(.purchases, key: "taool_key", level: .automatic, userID: " player-b ", bundleID: nil)
        checkIns.start(.flags, key: "taool_key", level: .automatic, userID: "player-b", bundleID: nil)
        await checkIns.checkIn(.launch)
        #expect(StubProtocol.requests.count == 2, "the launch's, then the sign-in's")
        let signIn = try body(StubProtocol.requests.last)
        #expect(signIn["reason"] as? String == "user")
        #expect(signIn["userId"] as? String == "player-b", "trimmed")
        #expect(purchases.prepared == [false, true], "StoreKit read again, all of it, for the new user")
        #expect(flags.answers.last?.transition == true, "the new user's picks apply at once")
        try FileManager.default.removeItem(at: folder)
    }

    @Test func outcomes() async {
        StubProtocol.respond = { _ in (400, Data()) }
        #expect(await client.send(report, key: "k", bundleID: "b") == .refused)
        StubProtocol.respond = { _ in (404, Data(#"{"error":"unknown_app"}"#.utf8)) }
        #expect(await client.send(report, key: "k", bundleID: "b") == .unknownApp)
        StubProtocol.respond = { _ in (503, Data()) }
        #expect(await client.send(report, key: "k", bundleID: "b") == .failed)
        StubProtocol.respond = { _ in nil }
        #expect(await client.send(report, key: "k", bundleID: "b") == .failed)
    }

    @Test @MainActor func oneCheckInHoweverManyStartIt() async throws {
        StubProtocol.respond = { _ in (200, Self.standardAnswer) }
        let (checkIns, folder) = checkIns()
        let purchases = FakePurchases()
        checkIns.attach(purchases)
        checkIns.start(.purchases, key: "taool_key", level: .automatic, bundleID: nil)
        // Both modifiers' scenes becoming active together, then again a moment later.
        async let first: Void = checkIns.becameActive()
        async let second: Void = checkIns.becameActive()
        _ = await (first, second)
        await checkIns.becameActive()
        #expect(StubProtocol.requests.count == 1)
        #expect(StubProtocol.requests.first?.url?.absoluteString == "https://api.test/v1/sync/com.example.app?key=taool_key")
        try FileManager.default.removeItem(at: folder)
    }

    @Test @MainActor func aColdLaunchChecksIn_ThenOnlyWhenDue_OrAsked() async throws {
        StubProtocol.respond = { _ in (200, Self.standardAnswer) }
        let (checkIns, folder) = checkIns(kept: kept(checkedIn: 60))
        await checkIns.becameActive()
        #expect(StubProtocol.requests.count == 1, "a cold launch a minute after the last")
        #expect(try body(StubProtocol.requests.last)["flush"] == nil, "arriving says nothing")
        await checkIns.becameActive()
        #expect(StubProtocol.requests.count == 1, "coming back waits for the interval")
        #expect(await checkIns.checkIn(.launch, at: .now))
        #expect(StubProtocol.requests.count == 2, "the app asking goes at once")

        // taool asked cold launches to wait: the next launch, a minute later, doesn't go.
        StubProtocol.respond = { _ in (200, Data(#"{"analytics":"standard","syncInterval":21600,"launchInterval":3600}"#.utf8)) }
        #expect(await checkIns.checkIn(.launch, at: .now))
        let (relaunched, _) = self.checkIns(in: folder)
        await relaunched.becameActive()
        #expect(StubProtocol.requests.count == 3)
        try FileManager.default.removeItem(at: folder)
    }

    @Test @MainActor func theOtherBuildsAppTransactionGoesOnce_AsTheEnvironmentChanges() async throws {
        StubProtocol.respond = { _ in (200, Self.standardAnswer) }
        // TestFlight's, kept before the App Store build was installed over it.
        var testFlight = kept(checkedIn: 60)
        testFlight.keptAppTransaction = KeptAppTransaction(signed: "testflight.jws.sig", isTestBuild: true)
        let (checkIns, folder) = checkIns(kept: testFlight)
        #expect(await checkIns.checkIn(.launch, at: .now))
        #expect(try body(StubProtocol.requests.last)["previousAppTransaction"] as? String == "testflight.jws.sig")
        #expect(await checkIns.checkIn(.launch, at: .now))
        #expect(try body(StubProtocol.requests.last)["previousAppTransaction"] == nil, "once: the App Store's is kept now")
        try FileManager.default.removeItem(at: folder)

        // Another App Store Apple Account's on the device never goes: one environment.
        var appStore = kept(checkedIn: 60)
        appStore.keptAppTransaction = KeptAppTransaction(signed: "another.jws.sig", isTestBuild: false)
        let (sameEnvironment, other) = self.checkIns(kept: appStore)
        #expect(await sameEnvironment.checkIn(.launch, at: .now))
        #expect(try body(StubProtocol.requests.last)["previousAppTransaction"] == nil)
        try FileManager.default.removeItem(at: other)
    }

    @Test @MainActor func leavingChecksInOnlyWhenDue() async throws {
        StubProtocol.respond = { _ in (200, Self.standardAnswer) }
        let (checkIns, folder) = checkIns(kept: kept(checkedIn: 7 * 3600))
        await checkIns.wentToBackground()
        #expect(StubProtocol.requests.count == 1, "a session that ends past the interval")
        #expect(try body(StubProtocol.requests.last)["flush"] as? Bool == true, "says it's leaving")
        await checkIns.wentToBackground()
        #expect(StubProtocol.requests.count == 1, "leaving again soon after")
        try FileManager.default.removeItem(at: folder)
    }

    @Test @MainActor func theAppLeavesWithItsLastScene() async throws {
        StubProtocol.respond = { _ in (200, Self.standardAnswer) }
        // Started only once both windows are active, so their cold launch sends nothing and leaving is still due.
        let (checkIns, folder) = checkIns(kept: kept(checkedIn: 7 * 3600), key: nil)
        let (window, other) = (UUID(), UUID())
        await checkIns.becameActive(scene: window)
        await checkIns.becameActive(scene: other)
        checkIns.start(.analytics, key: "taool_key", level: .automatic, bundleID: "com.example.app")
        await checkIns.left(scene: window)
        await checkIns.left(scene: window)
        #expect(StubProtocol.requests.isEmpty, "another window is still in use, and a window gone to the background then closed leaves once")
        await checkIns.left(scene: UUID())
        #expect(StubProtocol.requests.isEmpty, "a scene that never became active")
        await checkIns.left(scene: other)
        #expect(StubProtocol.requests.count == 1, "the last window leaving is the app leaving")
        #expect(try body(StubProtocol.requests.last)["flush"] as? Bool == true)
        try FileManager.default.removeItem(at: folder)
    }

    @Test @MainActor func theFlagsChangeAsTheAppComesToTheForeground() async throws {
        StubProtocol.respond = { _ in (200, Self.standardAnswer) }
        let (checkIns, folder) = checkIns()
        let flags = FakeFlags()
        checkIns.attach(flags: flags)
        let (window, other) = (UUID(), UUID())
        await checkIns.becameActive(scene: window)
        #expect(flags.foregrounds == 1)
        await checkIns.becameActive(scene: other)
        await checkIns.becameActive(scene: window)
        #expect(flags.foregrounds == 1, "another window, or one back from Control Center, is a screen in use")
        await checkIns.left(scene: window)
        await checkIns.left(scene: other)
        await checkIns.becameActive(scene: other)
        #expect(flags.foregrounds == 2, "back in the foreground")
        try FileManager.default.removeItem(at: folder)
    }

    @Test @MainActor func withoutAKey_nothingGoes_andAskingSaysSo() async {
        StubProtocol.respond = { _ in (200, Self.standardAnswer) }
        let (checkIns, _) = checkIns(key: nil)
        #expect(await checkIns.checkIn(.launch, at: .now) == false)
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test @MainActor func thePurchasesPartOnlyWithTaoolPurchases() async throws {
        StubProtocol.respond = { _ in (200, Self.standardAnswer) }
        let (alone, aloneFolder) = checkIns()
        await alone.checkIn(.launch)
        let analyticsOnly = try body(StubProtocol.requests.last)
        #expect(analyticsOnly["purchases"] == nil && analyticsOnly["appTransaction"] as? String == "app.jws.sig")
        #expect(analyticsOnly["device"] != nil, "standard facts by default")

        let (withPurchases, withFolder) = checkIns()
        let purchases = FakePurchases()
        withPurchases.attach(purchases)
        await withPurchases.checkIn(.launch)
        let both = try body(StubProtocol.requests.last)
        #expect(both["purchases"] as? [String: Any] != nil, "sent even with nothing in it")
        #expect(purchases.outcomes == [.answered(otherUser: nil, grants: nil)])
        try FileManager.default.removeItem(at: aloneFolder)
        try FileManager.default.removeItem(at: withFolder)
    }

    @Test @MainActor func anAnswerSayingNothingAboutPurchasesHandsBackWhatWent() async throws {
        // As for an app not connected to Subscriptions: no grants or other users' subscriptions.
        StubProtocol.respond = { _ in (200, Self.standardAnswer) }
        let (checkIns, folder) = checkIns()
        let purchases = FakePurchases()
        purchases.queued = ["t.jws.sig"]
        checkIns.attach(purchases)
        #expect(await checkIns.checkIn(.purchase))
        #expect(purchases.outcomes == [.answered(otherUser: nil, grants: nil)] && purchases.queued.isEmpty)
        #expect(StubProtocol.requests.count == 1, "nothing left to send again")
        try FileManager.default.removeItem(at: folder)
    }

    @Test @MainActor func theMostPrivateLevelHolds() async throws {
        StubProtocol.respond = { _ in (200, Data(#"{"analytics":"expanded","syncInterval":21600}"#.utf8)) }
        let (checkIns, folder) = checkIns()
        #expect(checkIns.level == .standard, "standard until taool says")
        await checkIns.checkIn(.launch)
        #expect(checkIns.level == .expanded, "as the taool app says")
        checkIns.start(.purchases, key: "taool_key", level: .standard, bundleID: nil)
        #expect(checkIns.level == .standard, "the code's ceiling")
        checkIns.start(.analytics, key: "taool_key", level: .minimal, bundleID: nil)
        #expect(checkIns.level == .minimal)
        checkIns.start(.analytics, key: "taool_key", level: .expanded, bundleID: nil)
        #expect(checkIns.level == .standard, "the more private of the two")
        await checkIns.checkIn(.launch, at: .now)
        #expect(try body(StubProtocol.requests.first)["level"] as? Int == 0, "automatic, whatever the taool app said")
        #expect(try body(StubProtocol.requests.last)["level"] as? Int == 2, "the code's, never what the taool app says")
        try FileManager.default.removeItem(at: folder)
    }

    @Test @MainActor func taoolAnalyticsAloneTakesTheUser() async throws {
        StubProtocol.respond = { _ in (200, Self.standardAnswer) }
        let (checkIns, folder) = checkIns(kept: kept(checkedIn: 60), sessionGrace: .milliseconds(50))
        checkIns.start(.analytics, key: "taool_key", level: .automatic, userID: "player-c", bundleID: nil)
        #expect(checkIns.userID == "player-c")
        await checkIns.becameActive()
        let launch = try body(StubProtocol.requests.last)
        #expect(launch["userId"] as? String == "player-c" && launch["purchases"] == nil && launch["flags"] == nil)
        try FileManager.default.removeItem(at: folder)
    }
}
