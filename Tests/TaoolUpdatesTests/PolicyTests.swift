// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import TaoolCore
import Testing
@testable import TaoolUpdates

struct VersionsTests {
    @Test(arguments: [
        ("1.10", "1.9", ComparisonResult.orderedDescending),
        ("1.8", "1.8.0", .orderedSame),
        ("26.37.73", "26.37.76", .orderedAscending),
        ("2", "1.99.99", .orderedDescending),
        ("1.0b", "1.0", .orderedSame),
    ])
    func compare(a: String, b: String, expected: ComparisonResult) {
        #expect(Versions.compare(a, b) == expected)
    }
}

struct PolicyStatusTests {
    /// 1.2 needs OS 26, 1.1 and 1.0 run on 18.
    private func policy(minimum: String? = nil) -> UpdatePolicy {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        return UpdatePolicy(
            appId: 1234567890,
            minimumVersion: minimum,
            versions: [
                .init(version: "1.2", minimumOsVersion: "26.0"),
                .init(version: "1.1", minimumOsVersion: "18.0"),
                .init(version: "1.0", minimumOsVersion: nil),
            ])
    }

    @Test func latestInstalled_isCurrent() {
        #expect(policy().status(appVersion: "1.2", osVersion: "26.1.0") == .current)
        #expect(policy().status(appVersion: "1.3", osVersion: "26.1.0") == .current, "a build newer than the store's")
    }

    @Test func older_updateAvailable_withStoreLink() throws {
        guard case .available(let release) = policy().status(appVersion: "1.1", osVersion: "26.0.0") else {
            Issue.record("expected available"); return
        }
        #expect(release.version == "1.2")
        #expect(release.appStoreURL.absoluteString.hasSuffix("apps.apple.com/app/id1234567890"))
    }

    @Test func olderOS_offeredTheNewestVersionItCanInstall() {
        guard case .available(let release) = policy().status(appVersion: "1.0", osVersion: "18.5.0") else {
            Issue.record("expected available"); return
        }
        #expect(release.version == "1.1")
        #expect(policy().status(appVersion: "1.1", osVersion: "18.5.0") == .current, "1.2 doesn't install on 18")
    }

    @Test func belowMinimum_required() {
        guard case .required(let release) = policy(minimum: "1.2").status(appVersion: "1.1", osVersion: "26.0.0") else {
            Issue.record("expected required"); return
        }
        #expect(release.version == "1.2")
    }

    @Test func minimumOSNotKnown_countsAsInstallable() {
        // 1.0's minimum OS isn't known: below a minimum of 1.0 on an OS older than 1.1's, it's offered, never "nothing runs".
        guard case .required(let release) = policy(minimum: "1.0").status(appVersion: "0.9", osVersion: "17.0.0") else {
            Issue.record("expected required"); return
        }
        #expect(release.version == "1.0")
    }

    @Test func belowMinimum_noVersionForThisOS_unsupported() {
        #expect(policy(minimum: "1.2").status(appVersion: "1.1", osVersion: "18.5.0") == .unsupported(requiredOSVersion: "26.0"))
        // 1.1 is enough and runs on 18: the OS to update to is 18, not the latest's 26.
        #expect(policy(minimum: "1.1").status(appVersion: "1.0", osVersion: "17.0.0") == .unsupported(requiredOSVersion: "18.0"))
    }

    @Test func minimumEqualsInstalled_notRequired() {
        #expect(policy(minimum: "1.1.0").status(appVersion: "1.1", osVersion: "18.0.0") == .current)
    }

    @Test func noVersionsKnown_current() {
        let empty = UpdatePolicy(appId: 1, minimumVersion: nil, versions: [])
        #expect(empty.status(appVersion: "1.0", osVersion: "26.0.0") == .current)
    }

    /// The API leaves out nulls: here minimumVersion and the older version's minimumOsVersion. What TaoolKit doesn't read
    /// (the latest's notes, the dates, which earlier builds read) is ignored.
    @Test func decodesTheApiAnswer() throws {
        let json = """
            {"appId":1234567890,"bundleId":"com.example","platform":"ios",
             "latest":{"version":"1.8.8","releasedAt":"2026-09-22T16:35:34Z","minimumOsVersion":"26.2","releaseNotes":"Add to Calendar"},
             "versions":[{"version":"1.8.8","releasedAt":"2026-09-22T16:35:34Z","minimumOsVersion":"26.2"},
                         {"version":"1.8.7","releasedAt":"2026-09-20T04:49:46Z"}]}
            """
        let policy = try Kit.decoder.decode(UpdatePolicy.self, from: Data(json.utf8))
        #expect(policy.versions.first?.version == "1.8.8")
        #expect(policy.minimumVersion == nil)
        #expect(policy.versions.count == 2)
        #expect(policy.versions[1].minimumOsVersion == nil)
        #expect(policy.status(appVersion: "1.8.7", osVersion: "26.2.0") != .current)
    }
}

struct UpdateCoverTests {
    private let release = AppRelease(version: "1.2", appStoreURL: AppRelease.appStoreURL(appId: 1234567890))
    private let appStoreURL = AppRelease.appStoreURL(appId: 1234567890)

    @Test func taoolsAnswer_coversOnlyWhenRequired() {
        #expect(UpdateCover(status: .required(release), serverRequired: false, appStoreURL: nil) == .required(release, appStoreURL: release.appStoreURL))
        #expect(UpdateCover(status: .unsupported(requiredOSVersion: "26.0"), serverRequired: false, appStoreURL: nil) == .unsupported(requiredOSVersion: "26.0"))
        #expect(UpdateCover(status: .available(release), serverRequired: false, appStoreURL: appStoreURL) == nil)
        #expect(UpdateCover(status: .current, serverRequired: false, appStoreURL: appStoreURL) == nil)
    }

    @Test func serverRefused_coversWhateverTaoolLastSaid() {
        // taool's last answer knew a newer version but not the raised minimum: update to it.
        #expect(UpdateCover(status: .available(release), serverRequired: true, appStoreURL: appStoreURL) == .required(release, appStoreURL: release.appStoreURL))
        // It knew nothing newer yet (the release came after): the App Store, without a version.
        #expect(UpdateCover(status: .current, serverRequired: true, appStoreURL: appStoreURL) == .required(nil, appStoreURL: appStoreURL))
        // Never asked taool at all: still covered, with no button until the refresh names the app.
        #expect(UpdateCover(status: .current, serverRequired: true, appStoreURL: nil) == .required(nil, appStoreURL: nil))
        #expect(UpdateCover(status: .unsupported(requiredOSVersion: "26.0"), serverRequired: true, appStoreURL: appStoreURL) == .unsupported(requiredOSVersion: "26.0"))
    }
}

struct WhatsNewPageTests {
    private let released = Date(timeIntervalSince1970: 1_790_000_000)
    private var page: WhatsNewPage {
        WhatsNewPage(id: "p1", url: URL(string: "https://pages.example.com/whatsnew/p1/index.html")!, version: "2.0", releasedAt: released)
    }

    @Test func newToThoseWhoHadTheAppBefore() {
        #expect(page.isNew(firstDownloaded: released.addingTimeInterval(-86_400)))
        #expect(page.isNew(firstDownloaded: nil), "StoreKit couldn't say: every page is new")
        #expect(!page.isNew(firstDownloaded: released.addingTimeInterval(3600)), "got the app after 2.0: nothing in it is new")
    }

    @Test func oncePerVersion_soAPageUploadedAgain_orAnOlderOneLiveAgain_isNotShownAgain() {
        #expect(page.isNewer(than: nil), "none shown yet")
        #expect(page.isNewer(than: "1.9"))
        #expect(!page.isNewer(than: "2.0"), "seen, or a new upload for a version already shown")
        #expect(!page.isNewer(than: "2.0.0"), "the same version, written longer")
        let older = WhatsNewPage(id: "p0", url: page.url, version: "1.9", releasedAt: released.addingTimeInterval(-30 * 86_400))
        #expect(!older.isNewer(than: "2.0"), "live again after 2.0's page was deleted")
    }

    @Test func olderBuilds_getTheUpdateBar_andThePageItsParameters() {
        #expect(page.needsUpdate(appVersion: "1.9.3"))
        #expect(!page.needsUpdate(appVersion: "2.0.0"))
        #expect(page.url(appVersion: "1.9.3", language: "sv").absoluteString == "https://pages.example.com/whatsnew/p1/index.html#version=1.9.3&language=sv&update=1")
        #expect(page.url(appVersion: "2.0", language: "pt_BR").absoluteString == "https://pages.example.com/whatsnew/p1/index.html#version=2.0&language=pt-BR")
        #expect(page.url(appVersion: "2.0", language: "no").absoluteString.hasSuffix("&language=no"), "as the app names it, never TaoolKit's own nb")
        #expect(page.url(appVersion: "2.0", language: "bg").absoluteString.hasSuffix("&language=bg"), "a language TaoolKit's text isn't in")
        #expect(page.url(appVersion: "1.9.3", language: "sv").query == nil, "after the #, so the request for the page is everyone's")

        let shown = PresentedWhatsNew(page: page, appVersion: "1.9", appStoreURL: AppRelease.appStoreURL(appId: 1))
        #expect(shown.updateTo == "2.0")
        #expect(PresentedWhatsNew(page: page, appVersion: "2.1", appStoreURL: nil).updateTo == nil)
        // The language the sheet shows, the lock or the app's, is the one the page reads.
        #expect(PresentedWhatsNew(page: page, appVersion: "1.9", appStoreURL: nil, language: "sv").url.absoluteString.contains("language=sv&update=1"))
    }

    @Test func aScreenOfTheAppsOwn_getsTheVersion_andTheUpdateOnlyWhenThisBuildIsOlder() {
        let older = TaoolUpdates.WhatsNew(shown: PresentedWhatsNew(page: page, appVersion: "1.9", appStoreURL: nil, language: "en"))
        #expect(older.version == "2.0")
        #expect(older.updateTo == "2.0")
        #expect(older.updateMessage?.contains("2.0") == true)
        #expect(older.pageURL.absoluteString.hasSuffix("update=1"), "the page it stands in for, as the built-in sheet would load it")
        #expect(older.id == "p1")

        let current = TaoolUpdates.WhatsNew(shown: PresentedWhatsNew(page: page, appVersion: "2.0", appStoreURL: nil, language: "en"))
        #expect(current.updateTo == nil)
        #expect(current.updateMessage == nil, "nothing to update to: no line for it")
        #expect(!current.button.isEmpty)
    }

    @Test func testFlightBuilds_seeTheNewestTestFlightPageAtOrBelowTheirVersion_whenItsTheNewer() {
        let twoOne = WhatsNewPage(id: "tf21", url: page.url, version: "2.1", releasedAt: nil)
        let twoTwo = WhatsNewPage(id: "tf22", url: page.url, version: "2.2", releasedAt: nil)
        let testing = [twoTwo, twoOne]
        #expect(WhatsNewPage.shown(live: page, testFlight: testing, isTestBuild: true, appVersion: "2.2") == twoTwo)
        #expect(WhatsNewPage.shown(live: page, testFlight: testing, isTestBuild: true, appVersion: "2.1") == twoOne, "2.2's isn't for it yet")
        #expect(WhatsNewPage.shown(live: nil, testFlight: testing, isTestBuild: true, appVersion: "2.1.3") == twoOne, "none live yet")
        #expect(WhatsNewPage.shown(live: page, testFlight: testing, isTestBuild: true, appVersion: "2.0") == page, "a build before 2.1")
        #expect(WhatsNewPage.shown(live: page, testFlight: testing, isTestBuild: false, appVersion: "2.2") == page, "from the App Store")
        let older = WhatsNewPage(id: "tf", url: page.url, version: "1.9", releasedAt: nil)
        #expect(WhatsNewPage.shown(live: page, testFlight: [older], isTestBuild: true, appVersion: "2.0") == page, "a newer page is live")
        let same = WhatsNewPage(id: "tf", url: page.url, version: "2.0.0", releasedAt: nil)
        #expect(WhatsNewPage.shown(live: page, testFlight: [same], isTestBuild: true, appVersion: "2.0") == page, "the live one, dated")
    }

    @Test func decodesThePageInTheAnswer() throws {
        let json = Data("""
            {"appId":1,"minimumVersion":null,"versions":[],
             "whatsNew":{"id":"3f2a","url":"https://pages.example.com/whatsnew/3f2a/index.html","version":"2.0","releasedAt":"2026-09-22T16:35:34Z"}}
            """.utf8)
        let policy = try Kit.decoder.decode(UpdatePolicy.self, from: json)
        #expect(policy.whatsNew?.version == "2.0")
        #expect(policy.whatsNew?.releasedAt != nil)
        let testing = try Kit.decoder.decode(UpdatePolicy.self, from: Data(#"{"appId":1,"versions":[],"testFlightPages":[{"id":"9c1b","url":"https://pages.example.com/whatsnew/9c1b/index.html","version":"2.1"}]}"#.utf8))
        #expect(testing.testFlightPages?.first?.version == "2.1")
        #expect(testing.testFlightPages?.first?.releasedAt == nil)
    }
}
