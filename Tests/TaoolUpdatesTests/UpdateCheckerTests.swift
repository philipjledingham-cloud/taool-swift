// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import TaoolCore
import Testing
@testable import TaoolUpdates

/// Answers requests from a closure. One test at a time uses it (the suite is serialized).
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: (URLRequest) -> (Int, Data)? = { _ in nil }
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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

@Suite(.serialized)
struct UpdateCheckerTests {
    private static let body = Data("""
        {"appId":1,"bundleId":"com.example","platform":"ios","minimumVersion":"1.1",
         "latest":{"version":"1.2","releasedAt":"2026-09-22T16:35:34Z","minimumOsVersion":"26.0"},
         "versions":[{"version":"1.2","releasedAt":"2026-09-22T16:35:34Z","minimumOsVersion":"26.0"}]}
        """.utf8)

    /// A checker as a fresh launch has it, keeping answers at `url`.
    private func checker(keptAt url: URL = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())/updates.json")) -> UpdateChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return UpdateChecker(session: URLSession(configuration: config), baseURL: URL(string: "https://api.test")!, file: StateFile(url: url))
    }

    init() { StubProtocol.requests = [] }

    @Test func asksWithKeyAndPlatform_thenSpacesRequestsOut() async throws {
        let checker = checker()
        StubProtocol.respond = { _ in (200, Self.body) }
        let now = Date()

        let policy = await checker.policy(key: "taool_k", bundleID: "com.example", platform: "ios", now: now)
        #expect(policy?.minimumVersion == "1.1")
        #expect(StubProtocol.requests.first?.url?.absoluteString == "https://api.test/v1/updates/com.example/ios?key=taool_k")

        // Asked this launch: not again within the hour.
        _ = await checker.policy(key: "taool_k", bundleID: "com.example", platform: "ios", now: now.addingTimeInterval(30 * 60))
        #expect(StubProtocol.requests.count == 1)
        _ = await checker.policy(key: "taool_k", bundleID: "com.example", platform: "ios", now: now.addingTimeInterval(61 * 60))
        #expect(StubProtocol.requests.count == 2)
    }

    @Test func forced_asksAgain_andKeepsTheLastAnswerOffline() async {
        let checker = checker()
        StubProtocol.respond = { _ in (200, Self.body) }
        let now = Date()
        _ = await checker.policy(key: "taool_k", bundleID: "com.example", platform: "ios", now: now)
        // A server's 426: ask now, not in an hour.
        _ = await checker.policy(key: "taool_k", bundleID: "com.example", platform: "ios", force: true, now: now.addingTimeInterval(60))
        #expect(StubProtocol.requests.count == 2)
        StubProtocol.respond = { _ in nil }
        let offline = await checker.policy(key: "taool_k", bundleID: "com.example", platform: "ios", force: true, now: now.addingTimeInterval(120))
        #expect(offline?.minimumVersion == "1.1")
    }

    @Test func checksAtTheSameMoment_shareOneRequest() async {
        let checker = checker()
        // Slow enough that the second check starts while the first is still waiting.
        StubProtocol.respond = { _ in Thread.sleep(forTimeInterval: 0.3); return (200, Self.body) }
        async let prompts = checker.policy(key: "taool_k", bundleID: "com.example", platform: "ios")
        async let whatsNew = checker.policy(key: "taool_k", bundleID: "com.example", platform: "ios")
        let (first, second) = await (prompts, whatsNew)
        #expect(first?.minimumVersion == "1.1")
        #expect(second?.minimumVersion == "1.1")
        #expect(StubProtocol.requests.count == 1)
    }

    @Test func afterAFailure_waitsBeforeAskingAgain() async {
        let checker = checker()
        StubProtocol.respond = { _ in nil }
        let now = Date()
        _ = await checker.policy(key: "taool_k", bundleID: "com.example", platform: "ios", now: now)
        _ = await checker.policy(key: "taool_k", bundleID: "com.example", platform: "ios", now: now.addingTimeInterval(60))
        #expect(StubProtocol.requests.count == 1, "not at every open while taool can't be reached")
        StubProtocol.respond = { _ in (200, Self.body) }
        let policy = await checker.policy(key: "taool_k", bundleID: "com.example", platform: "ios", now: now.addingTimeInterval(6 * 60))
        #expect(StubProtocol.requests.count == 2 && policy?.minimumVersion == "1.1")
    }

    @Test func offline_usesTheLastAnswer_orNothing() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())/updates.json")
        let checker = checker(keptAt: url)
        StubProtocol.respond = { _ in nil }
        #expect(await checker.policy(key: "taool_k", bundleID: "com.example", platform: "ios") == nil)

        // A later launch (a new checker on the same file) that knew an answer keeps using it offline.
        StubProtocol.respond = { _ in (200, Self.body) }
        _ = await checker.policy(key: "taool_k", bundleID: "com.example.other", platform: "ios")
        let nextLaunch = self.checker(keptAt: url)
        StubProtocol.respond = { _ in nil }
        let offline = await nextLaunch.policy(key: "taool_k", bundleID: "com.example.other", platform: "ios", now: Date().addingTimeInterval(2 * 3600))
        #expect(offline?.versions.first?.version == "1.2")
    }

    /// An answer naming What's New page `id`, so which answer shows can be told whatever version runs the tests.
    private static func answer(page id: String) -> Data {
        Data("""
            {"appId":1,"versions":[{"version":"1.2"}],
             "whatsNew":{"id":"\(id)","url":"https://pages.example.com/whatsnew/\(id)/index.html","version":"1.2"}}
            """.utf8)
    }

    @MainActor @Test func state_showsTheSavedAnswerFirst_thenTaoolsAsTheAppComesToTheForeground() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())/updates.json")
        let platform = TaoolUpdates.platform
        StubProtocol.respond = { _ in (200, Self.answer(page: "p1")) }
        _ = await checker(keptAt: url).policy(key: "taool_k", bundleID: "com.example", platform: platform)

        // The next launch shows what was saved before asking anything.
        StubProtocol.requests = []
        let state = UpdateState(checker: checker(keptAt: url))
        #expect(state.result.whatsNew?.id == "p1")
        #expect(!state.result.isSettled, "What's New waits for this launch's answer")
        #expect(state.result(for: "").whatsNew == nil, "without a key, nothing saved shows")

        // Coming to the foreground, it's due: taool's answer replaces it where it differs.
        StubProtocol.respond = { _ in (200, Self.answer(page: "p2")) }
        let later = Date().addingTimeInterval(2 * 3600)
        await state.becameActive(scene: UUID(), key: "taool_k", bundleID: "com.example", now: later)
        #expect(state.result.whatsNew?.id == "p2" && state.result.isSettled)
        #expect(StubProtocol.requests.count == 1)

        // Another window becoming active isn't the app coming to the foreground: nothing asked.
        await state.becameActive(scene: UUID(), key: "taool_k", bundleID: "com.example", now: later.addingTimeInterval(7200))
        #expect(StubProtocol.requests.count == 1)
    }

    @MainActor @Test func serverRequired_asksOnceALaunch_unlessTaoolNeverAnswered() async {
        let state = UpdateState(checker: checker())
        // Offline with nothing kept: each 426 asks again.
        StubProtocol.respond = { _ in nil }
        await state.serverRequired(key: "taool_k", bundleID: "com.example")
        await state.serverRequired(key: "taool_k", bundleID: "com.example")
        #expect(StubProtocol.requests.count == 2)
        // Once taool answered, even that it has no policy, a later 426 doesn't ask again.
        StubProtocol.respond = { _ in (404, Data(#"{"error":"unknown_app"}"#.utf8)) }
        await state.serverRequired(key: "taool_k", bundleID: "com.example")
        await state.serverRequired(key: "taool_k", bundleID: "com.example")
        #expect(StubProtocol.requests.count == 3)
    }

    @Test func savedAtLaunch_isTheAnswerKeptLast_withoutAsking() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())/updates.json")
        StubProtocol.respond = { _ in (200, Self.body) }
        _ = await checker(keptAt: url).policy(key: "taool_k", bundleID: "com.example", platform: "ios")
        StubProtocol.requests = []
        #expect(checker(keptAt: url).savedAtLaunch?.minimumVersion == "1.1")
        #expect(checker().savedAtLaunch == nil, "nothing kept")
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func unknownApp_nil_andServerErrors_failOpen() async {
        let checker = checker()
        StubProtocol.respond = { _ in (404, Data(#"{"error":"unknown_app"}"#.utf8)) }
        #expect(await checker.policy(key: "taool_k", bundleID: "com.example.unknown", platform: "ios") == nil)
        StubProtocol.respond = { _ in (500, Data()) }
        #expect(await checker.policy(key: "taool_k", bundleID: "com.example.broken", platform: "ios") == nil)
    }

    @Test func simulation_inDebug() async {
        #if DEBUG
        #expect(await TaoolUpdates.status(key: "", simulating: .unsupported) == .unsupported(requiredOSVersion: "99.0"))
        #endif
    }
}
