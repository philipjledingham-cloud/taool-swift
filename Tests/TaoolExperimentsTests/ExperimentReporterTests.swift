// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import TaoolCore
import Testing
@testable import TaoolExperiments

/// Answers requests from a closure. One test at a time uses it (the suite is serialized).
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

@Suite(.serialized)
struct ExperimentReporterTests {
    private let variants = ["control", "freeTrial"]

    init() {
        StubProtocol.requests = []
        StubProtocol.respond = { _ in nil }
    }

    private func reporter(_ store: ExperimentStore) -> ExperimentReporter {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return ExperimentReporter(store: store, session: URLSession(configuration: config),
                                  baseURL: URL(string: "https://api.test")!,
                                  appTransaction: { AppTransactionFacts(signed: "app.jws.sig", id: "705000000000001", environment: .sandbox, downloadedAt: nil) })
    }

    private func events() -> [[String: Any]] {
        StubProtocol.requests.filter { $0.httpMethod == "POST" }.compactMap {
            $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    @Test func activate_asksForWinners_thenReportsExposuresAndPurchases() async throws {
        let store = store()
        let reporter = reporter(store)
        let name = store.variant(experiment: "paywall-button", variants: variants)
        store.addGoal("feature-used")
        store.addTransaction(id: 7, purchase: 7, jws: "header.payload.signature", startedAt: .now)
        StubProtocol.respond = { request in
            request.httpMethod == "POST" ? (200, Data(#"{"variants":[]}"#.utf8)) : (200, Data(#"{"winners":[{"experiment":"onboarding","variant":"short"}]}"#.utf8))
        }

        await reporter.activate(key: "taool_k", bundleID: "com.example")

        #expect(StubProtocol.requests.first?.url?.absoluteString == "https://api.test/v1/experiments/com.example?key=taool_k")
        #expect(store.variant(experiment: "onboarding", variants: ["long", "short"]) == "short")
        let post = try #require(StubProtocol.requests.last)
        #expect(post.url?.absoluteString == "https://api.test/v1/experiments/com.example/events?key=taool_k")
        let body = try #require(events().first)
        #expect(body["environment"] as? String == "sandbox")
        #expect(body["personId"] as? String == "705000000000001")
        #expect(body["previousPersonId"] == nil, "never reported as anyone else")
        let exposure = try #require((body["exposures"] as? [[String: Any]])?.first)
        #expect(exposure["experiment"] as? String == "paywall-button")
        #expect(exposure["variant"] as? String == name)
        #expect(exposure["variants"] as? [String] == variants)
        #expect((exposure["at"] as? String)?.hasSuffix("Z") == true)
        #expect((body["goals"] as? [[String: Any]])?.first?["name"] as? String == "feature-used")
        #expect(body["transactions"] as? [String] == ["header.payload.signature"])
        #expect(store.nextBatch().isEmpty, "sent, so forgotten")
    }

    @Test func answer_variants_areShownFromTheNextForeground() async {
        let store = store()
        let reporter = reporter(store)
        let shown = store.variant(experiment: "paywall", variants: variants)
        let counted = variants.first { $0 != shown }!
        StubProtocol.respond = { request in
            request.httpMethod == "POST"
                ? (200, Data(#"{"variants":[{"experiment":"paywall","variant":"\#(counted)"}]}"#.utf8))
                : (200, Data(#"{"winners":[]}"#.utf8))
        }

        await reporter.activate(key: "taool_k", bundleID: "com.example")
        #expect(store.variant(experiment: "paywall", variants: variants) == shown, "the screen in use never changes")
        store.showWaiting()
        #expect(store.variant(experiment: "paywall", variants: variants) == counted, "the user's other device came first")
    }

    @Test func offline_keepsTheReport_forNextTime() async {
        let store = store()
        let reporter = reporter(store)
        _ = store.variant(experiment: "paywall", variants: variants)

        await reporter.activate(key: "taool_k", bundleID: "com.example")
        #expect(store.nextBatch().exposures.count == 1)

        StubProtocol.respond = { _ in (200, Data(#"{"variants":[],"winners":[]}"#.utf8)) }
        await reporter.flush()
        #expect(store.nextBatch().isEmpty)
    }

    @Test func unknownApp_keepsTheReport_andEndsNothing() async {
        let store = store()
        let reporter = reporter(store)
        _ = store.variant(experiment: "paywall", variants: variants)
        store.setWinners(["onboarding": variants[1]], fetchedAt: .distantPast)
        StubProtocol.respond = { _ in (404, Data(#"{"error":"unknown_app"}"#.utf8)) }

        await reporter.activate(key: "taool_k", bundleID: "com.example")
        #expect(store.nextBatch().exposures.count == 1, "kept until taool knows the app")
        #expect(variants.contains(store.variant(experiment: "paywall", variants: variants)))
        #expect(store.variant(experiment: "onboarding", variants: variants) == variants[1], "an ended experiment keeps its winner")
    }

    @Test func winners_areAskedOnceALaunch_thenHourly() async {
        let store = store()
        let reporter = reporter(store)
        StubProtocol.respond = { _ in (200, Data(#"{"winners":[]}"#.utf8)) }
        let now = Date()

        await reporter.activate(key: "taool_k", bundleID: "com.example", now: now)
        await reporter.activate(key: "taool_k", bundleID: "com.example", now: now.addingTimeInterval(30 * 60))
        #expect(StubProtocol.requests.count == 1)
        await reporter.activate(key: "taool_k", bundleID: "com.example", now: now.addingTimeInterval(61 * 60))
        #expect(StubProtocol.requests.count == 2)
    }

    @Test func noKey_sendsNothing() async {
        let store = store()
        _ = store.variant(experiment: "paywall", variants: variants)
        await reporter(store).activate(key: "", bundleID: "com.example")
        #expect(StubProtocol.requests.isEmpty)
    }
}
