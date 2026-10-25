// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import SwiftUI
import TaoolCore

extension View {
    /// What's New: the app's What's New page, a page of your own design about a version, uploaded
    /// in the taool app (taool Pro), shown once in a sheet to each user who had the app before
    /// that version, whether or not they've updated yet. It asks taool as the app comes to the foreground, in the
    /// same check as `.taoolUpdatePrompts(key:)` when both are used, and a page shows once this launch has taool's
    /// answer, or after 3 seconds the one the device heard of before.
    /// Put it on the root view of each scene.
    ///
    /// - Parameters:
    ///   - key: The account's key, from the taool app's TaoolKit page. Public: it's fine to ship in the app.
    ///   - mode: When the page shows: `.held` while your paywall, onboarding or own sheet is up,
    ///     `.manual` for only `TaoolUpdates.showWhatsNew()`.
    ///   - bundleID: The App Store app's bundle ID, when a debug build uses a different one.
    public func taoolWhatsNew(key: String, mode: WhatsNewMode = .automatic, bundleID: String? = nil) -> some View {
        modifier(WhatsNewModifier(key: key, bundleID: bundleID, mode: mode))
    }
}

/// When `.taoolWhatsNew(key:)` shows the page.
public enum WhatsNewMode: Sendable, Equatable {
    /// Once this launch has taool's answer, once the page's version is on the App Store.
    case automatic
    /// Not yet, while your paywall, onboarding or a sheet of your own is showing: it shows as
    /// soon as this goes back to `.automatic`.
    case held
    /// Only from `TaoolUpdates.showWhatsNew()`, such as a What's New row in your settings.
    case manual
}

extension TaoolUpdates {
    /// Shows the app's current What's New page again, even to a user who has seen it: for a
    /// What's New row in your settings. Does nothing without one. Needs `.taoolWhatsNew(key:)`.
    public static func showWhatsNew() {
        Task { @MainActor in WhatsNewState.shared.request() }
    }

    /// Whether there's a What's New page for `showWhatsNew()`, for a settings row shown only then.
    /// From `.taoolWhatsNew(key:)`'s answer, so no request; views reading it update with it.
    /// False without the modifier, and until this launch has taool's answer (or has waited for it), as the app opens.
    @MainActor public static var hasWhatsNew: Bool { WhatsNewState.shared.page != nil }
}

struct WhatsNewModifier: ViewModifier {
    let key: String
    let bundleID: String?
    let mode: WhatsNewMode

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.taoolWhatsNewScreen) private var customScreen
    @State private var shown: PresentedWhatsNew?

    private var requirement: ServerRequirement { .shared }
    private var state: WhatsNewState { .shared }
    /// Every scene's answer (`UpdateState`): the live page, and what the sheet needs besides. None without a key.
    private var check: TaoolUpdates.CheckResult { UpdateState.shared.result(for: key) }

    func body(content: Content) -> some View {
        content
            .sheet(item: $shown) { shown in
                if let customScreen {
                    CustomWhatsNew(shown: shown, screen: customScreen)
                } else {
                    WhatsNewSheet(shown: shown)
                }
            }
            // Held back until the app's own onboarding or sheet is done.
            .onChange(of: mode) { Task { await showIfDue() } }
            // A request is one scene's, the first active one to see it.
            .onChange(of: state.isRequested) {
                guard state.isRequested, scenePhase == .active else { return }
                state.isRequested = false
                if let page = state.page, !mustUpdate { shown = presenting(page) }
            }
            .updateSceneUse(key: key, bundleID: bundleID)
            // Once the launch has settled (`isSettled`), never on the answer saved alone; shown only to an active scene.
            .task(id: scenePhase == .active ? check : nil) {
                guard scenePhase == .active, check.isSettled else { return }
                let page = await WhatsNewPage.shown(live: check.whatsNew, testFlight: check.testFlightPages, appVersion: TaoolUpdates.appVersion)
                // A newer answer came while StoreKit was asked, and its own run works it out.
                guard !Task.isCancelled else { return }
                if page != state.page { state.page = page }
                await showIfDue()
            }
    }

    /// This version must update, by taool's answer or the app's server's 426: the page waits until
    /// it has, so it never shows over the update screen, and none of it is for a version that can't be used.
    private var mustUpdate: Bool {
        UpdateCover(status: check.status, serverRequired: requirement.isRequired, appStoreURL: check.appStoreURL) != nil
    }

    /// Shows the live page once per version to a user who had the app before it, when the app
    /// isn't holding it back.
    private func showIfDue() async {
        guard mode == .automatic, !mustUpdate, shown == nil, let page = state.page, page != state.tried,
              page.isNewer(than: PromptMemory.shared.kept.whatsNewShown) else { return }
        // Before the wait, so scenes becoming active together show it once.
        state.tried = page
        // Still the page once StoreKit has answered: taool's answer may have changed it meanwhile.
        guard page.isNew(firstDownloaded: await PromptMemory.shared.firstDownloaded()), state.page == page else { return }
        shown = presenting(page)
    }

    private func presenting(_ page: WhatsNewPage) -> PresentedWhatsNew {
        PresentedWhatsNew(page: page, appVersion: TaoolUpdates.appVersion, appStoreURL: check.appStoreURL,
                          language: check.wording.language)
    }
}

extension View {
    /// What's New in your own design, for every `.taoolWhatsNew` inside it: put it once, after the modifiers on the
    /// root view, as `.taoolUpdateRequiredScreen` is. TaoolKit still decides when it shows: once per version, to users
    /// who had the app before it, held while `mode` says so, never over the update screen, TestFlight pages in
    /// TestFlight. Your screen fills the sheet in place of the page, and the sheet counts as shown when it appears.
    /// For an app with a What's New of its own: still upload a page for each version in the taool app, since it's
    /// what tells TaoolKit the version has news, and the page is still what `pageURL` and `WhatsNewPageSheet` show.
    ///
    /// ```swift
    /// ContentView()
    ///     .taoolWhatsNew(key: "taool_public_…")
    ///     .taoolWhatsNewScreen { whatsNew in
    ///         if let release = MyReleases[whatsNew.version] {
    ///             MyWhatsNew(release)                          // closes with @Environment(\.dismiss)
    ///         } else {
    ///             TaoolUpdates.WhatsNewPageSheet(whatsNew)    // a version this build knows nothing about: the page
    ///         }
    ///     }
    /// ```
    public func taoolWhatsNewScreen<Screen: View>(@ViewBuilder _ screen: @escaping (TaoolUpdates.WhatsNew) -> Screen) -> some View {
        environment(\.taoolWhatsNewScreen, WhatsNewScreen { AnyView(screen($0)) })
    }
}

extension TaoolUpdates {
    /// What a What's New of your own design shows (`.taoolWhatsNewScreen`): which version it's about, and when
    /// this build is older than that, TaoolKit's words and button for the update.
    public struct WhatsNew: Identifiable {
        /// The version the news is about: "2.0". Compare it to your own releases' versions.
        public let version: String
        /// The version to update to, when this build is older than `version`: what's new isn't in it yet.
        public let updateTo: String?
        /// "Update to version 2.0 to get what's new.", when there's `updateTo`.
        public let updateMessage: String?
        /// The label for the button that opens the App Store: "Update".
        public let button: String
        /// The page uploaded in the taool app for this version, with what it reads after its `#`.
        public let pageURL: URL
        let shown: PresentedWhatsNew
        private let openAction: () -> Void

        public var id: String { shown.id }

        init(shown: PresentedWhatsNew, open: @escaping () -> Void = {}) {
            let strings = UpdateStrings(language: shown.language)
            version = shown.page.version
            updateTo = shown.updateTo
            updateMessage = shown.updateTo.map { strings.format("whatsNew.update", $0) }
            button = strings["button.update"]
            pageURL = shown.url
            self.shown = shown
            openAction = open
        }

        /// Opens the app's page in the App Store, for `updateTo`. Does nothing before taool has said where it is.
        public func open() { openAction() }
    }

    /// TaoolKit's own What's New sheet, the uploaded page in a web view, for a `.taoolWhatsNewScreen` that has
    /// nothing of its own for a version, such as a newer one than this build.
    public struct WhatsNewPageSheet: View {
        private let whatsNew: WhatsNew

        public init(_ whatsNew: WhatsNew) { self.whatsNew = whatsNew }

        public var body: some View { WhatsNewSheet(shown: whatsNew.shown) }
    }
}

/// `.taoolWhatsNewScreen`'s screen, in a struct since `@Entry` warns of a bare closure, which never compares equal.
struct WhatsNewScreen: Sendable {
    let make: @MainActor (TaoolUpdates.WhatsNew) -> AnyView
}

extension EnvironmentValues {
    @Entry var taoolWhatsNewScreen: WhatsNewScreen? = nil
}

/// The app's own What's New in the sheet, counted as shown once it's up: there's no page to load first.
private struct CustomWhatsNew: View {
    let shown: PresentedWhatsNew
    let screen: WhatsNewScreen
    @Environment(\.openURL) private var openURL

    var body: some View {
        screen.make(TaoolUpdates.WhatsNew(shown: shown) { if let url = shown.appStoreURL { openURL(url) } })
            .onAppear { PromptMemory.shared.shown(shown.page) }
    }
}

/// A page the update check names: the newest whose version is on the App Store, or the one TestFlight builds see before then.
struct WhatsNewPage: Codable, Equatable, Sendable {
    /// New with every upload, a new page for the same version included.
    let id: String
    let url: URL
    /// The version it's about.
    let version: String
    /// When that version came out, when taool knows.
    let releasedAt: Date?

    /// The page this build shows, StoreKit asked whether it's a test build only when there are TestFlight pages, so an
    /// app without them never waits on it.
    static func shown(live: WhatsNewPage?, testFlight: [WhatsNewPage], appVersion: String) async -> WhatsNewPage? {
        guard !testFlight.isEmpty, await AppTransactionFacts.read()?.isTestBuild == true else { return live }
        return shown(live: live, testFlight: testFlight, isTestBuild: true, appVersion: appVersion)
    }

    /// The live page; in a TestFlight build (or Xcode's), the newest TestFlight page at or below its version when it's
    /// about a newer version than the live one, which wins a tie.
    static func shown(live: WhatsNewPage?, testFlight: [WhatsNewPage], isTestBuild: Bool, appVersion: String) -> WhatsNewPage? {
        guard isTestBuild, let testing = testFlight.filter({ !Versions.isNewer($0.version, than: appVersion) })
            .max(by: { Versions.isNewer($1.version, than: $0.version) }) else { return live }
        guard let live else { return testing }
        return Versions.isNewer(testing.version, than: live.version) ? testing : live
    }

    /// Nothing in it is new to a user who first got the app after its version came out. Nil
    /// when StoreKit can't say: then it's new to everyone.
    func isNew(firstDownloaded: Date?) -> Bool {
        guard let releasedAt, let firstDownloaded else { return true }
        return firstDownloaded < releasedAt
    }

    /// About a newer version than the newest whose page this device has shown, or any when it
    /// has shown none: each version's page shows once.
    func isNewer(than shown: String?) -> Bool {
        shown.map { Versions.isNewer(version, than: $0) } ?? true
    }

    /// This build is older than the page's version: the sheet shows the update bar.
    func needsUpdate(appVersion: String) -> Bool { Versions.isNewer(version, than: appVersion) }

    /// The page's address with what it can read after its `#`: `version`, the running version;
    /// `language`, the one the app runs in or the one locked in taool, as the app names it (only
    /// `_` made `-`), so a page in several languages can show the developer's own, even one
    /// TaoolKit's text isn't in; and `update=1` below the version the page is about, for a page
    /// that says more to users who haven't updated. After the `#`, never in the query, so none of
    /// it leaves the device: the request for the page is the same for everyone.
    func url(appVersion: String, language: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var hash = URLComponents()
        hash.queryItems = [URLQueryItem(name: "version", value: appVersion),
                           URLQueryItem(name: "language", value: language.replacingOccurrences(of: "_", with: "-"))]
        if Versions.isNewer(version, than: appVersion) { hash.queryItems?.append(URLQueryItem(name: "update", value: "1")) }
        components.percentEncodedFragment = hash.percentEncodedQuery
        return components.url ?? url
    }
}

/// A What's New page being shown, with what the sheet needs besides.
struct PresentedWhatsNew: Identifiable, Equatable {
    let page: WhatsNewPage
    let url: URL
    /// The version to update to, when this build is older than the page's.
    let updateTo: String?
    let appStoreURL: URL?
    /// TaoolKit's language, the app's or the one locked in taool, for the sheet's own text.
    let language: String

    var id: String { page.id }

    init(page: WhatsNewPage, appVersion: String, appStoreURL: URL?, language: String = RunningApp.language) {
        self.page = page
        url = page.url(appVersion: appVersion, language: language)
        updateTo = page.needsUpdate(appVersion: appVersion) ? page.version : nil
        self.appStoreURL = appStoreURL
        self.language = language
    }
}

/// What `.taoolWhatsNew(key:)` shares with `TaoolUpdates`' statics: the page its answer names for
/// this build (`hasWhatsNew`), and a `showWhatsNew()` call waiting for a scene to show the page.
@MainActor
@Observable
final class WhatsNewState {
    static let shared = WhatsNewState()
    /// The page this build shows: the live one, or in TestFlight one of the TestFlight pages.
    var page: WhatsNewPage?
    /// The page shown on its own this launch: one that fails to load isn't tried again until the next.
    var tried: WhatsNewPage?
    var isRequested = false

    func request() { isRequested = true }
}
