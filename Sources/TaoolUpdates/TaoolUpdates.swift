// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import Observation
import os
import TaoolCore

#if !os(iOS) && !os(macOS)
// Update prompts and What's New go by the App Store's versions for the app's platform, which TaoolKit reads for iOS and
// the Mac, and the update screen names those two alone (Device.osName, the App Store link).
#error("TaoolUpdates supports iOS and macOS apps. TaoolKit's other products support tvOS, watchOS and visionOS too.")
#endif

/// Update checks: whether this install of the app is out of date, from the latest App
/// Store version (taool watches it) and the minimum version the developer set in taool, and
/// the app's What's New page, which comes in the same answer.
///
/// ```swift
/// ContentView()
///     .taoolUpdatePrompts(key: "taool_public_…")   // a banner when an update is available, a full screen when it's required
///     .taoolWhatsNew(key: "taool_public_…")        // your What's New page, once, to everyone who had the app before its version
///     .taoolTint(.orange)                          // optional: their colors, else the app's AccentColor
///
/// // Or your own UI:
/// switch await TaoolUpdates.status(key: "taool_public_…") { … }
///
/// // When your own server refuses a request with 426 (it read the same minimum from taool):
/// TaoolUpdates.serverRequiredUpdate()
/// ```
///
/// Checks never block the app or throw. When taool can't be reached, the last answer
/// is used, and with none the app is `.current`.
public enum TaoolUpdates {
    private static let log = Logger(subsystem: "TaoolKit", category: "updates")

    /// This install's status.
    /// - Parameters:
    ///   - key: The account's key, from the taool app's TaoolKit page. Public: it's fine to ship
    ///     in the app.
    ///   - bundleID: The app to check. Defaults to this app's; pass the App Store
    ///     app's when a debug build uses a different bundle ID.
    ///   - simulating: Returns a fake status in DEBUG builds, to try out the UI. Ignored
    ///     in release builds.
    public static func status(key: String, bundleID: String? = nil, simulating simulation: UpdateSimulation? = nil) async -> UpdateStatus {
        #if DEBUG
        if let simulation { return simulation.status }
        #endif
        return await UpdateState.shared.status(key: key, bundleID: bundleID)
    }

    /// What one check found: the status, the app's App Store link when taool has said which app
    /// it is, its What's New page and those TestFlight builds see first, and what the prompts say.
    struct CheckResult: Equatable {
        var status = UpdateStatus.current
        var appStoreURL: URL?
        var whatsNew: WhatsNewPage?
        var testFlightPages: [WhatsNewPage] = []
        var wording = UpdateWording.initial
        /// This launch has taool's answer (or one saved minutes ago, not asked again, `RefreshSchedule`), taool couldn't
        /// be reached, or the wait for it is over (`UpdateState.pageWait`): What's New takes a page only then, so one fixed
        /// or taken down since an older answer was saved isn't shown.
        var isSettled = false
    }

    /// Call when your own server refuses a request with 426 because this version is below the
    /// minimum you set in taool. `.taoolUpdatePrompts(key:)` covers the app with its update-required
    /// screen at once, without asking taool first (your server already did), and fills in the
    /// version to update to from taool in the background. It stays until the app is relaunched,
    /// which an update does. Safe to call from any thread, as often as requests fail.
    public static func serverRequiredUpdate() {
        Task { @MainActor in ServerRequirement.shared.require() }
    }

    /// This build's version (`CFBundleShortVersionString`). Send it with each request to your
    /// server, in an `X-App-Version` header, so it can refuse versions below your minimum.
    public static var appVersion: String { RunningApp.version ?? "0" }

    /// "ios" or "macos": which of the app's policies a server that serves both should check.
    public static var platform: String { RunningApp.platform }

    /// The app to ask taool about: nil without a key, which is said once.
    static func bundleToCheck(key: String, bundleID: String?) -> String? {
        guard !key.isEmpty else {
            Notice.once("No taool key, so no update check. The key is on the taool app's TaoolKit page.", log: log)
            return nil
        }
        ServerKeyGuard.check(key, log: log)
        return bundleID ?? Bundle.main.bundleIdentifier
    }

    /// What an answer means for this install, worked out on the device; none is `.current`.
    static func result(from policy: UpdatePolicy?) -> CheckResult {
        guard let policy else { return CheckResult() }
        return CheckResult(status: policy.status(appVersion: appVersion, osVersion: RunningApp.osVersion),
                           appStoreURL: AppRelease.appStoreURL(appId: policy.appId), whatsNew: policy.whatsNew,
                           testFlightPages: policy.testFlightPages ?? [], wording: UpdateWording(policy: policy))
    }
}

/// What update prompts and What's New show, one for every scene, and what `TaoolUpdates.status` and `UpdateStatus.text`
/// read. A launch starts on the answer saved last time, so a version below the minimum is covered from the first frame
/// and an available update's banner is already there; What's New waits for taool's answer, `pageWait` at most. As the
/// app comes to the foreground (its first scene becoming active, never another window or coming back from Control
/// Center) it asks taool when that's due (`RefreshSchedule`), and changes only where taool's answer differs.
@MainActor
@Observable
final class UpdateState {
    static let shared = UpdateState()

    private(set) var result: TaoolUpdates.CheckResult
    private let checker: UpdateChecker
    @ObservationIgnored private var scenes = ScenesInUse()
    /// A 426 has asked taool this launch: a view with the modifier appearing after it doesn't ask again.
    @ObservationIgnored private var askedForRequirement = false
    /// How long What's New waits for taool's answer at a launch before it shows the saved page. The check itself goes on.
    static let pageWait = Duration.seconds(3)

    init(checker: UpdateChecker = .shared) {
        self.checker = checker
        result = TaoolUpdates.result(from: checker.savedAtLaunch)
    }

    /// A scene became active (`UpdatePromptsModifier`, `WhatsNewModifier`): the first, as the app comes to the foreground.
    func becameActive(scene: UUID, key: String, bundleID: String?, now: Date = .now) async {
        guard scenes.becameActive(scene) else { return }
        if !result.isSettled {
            // taool took longer than What's New waits: the saved answer stands for now.
            Task { [weak self] in
                try? await Task.sleep(for: Self.pageWait)
                if let self, !result.isSettled { result.isSettled = true }
            }
        }
        await ask(key: key, bundleID: bundleID, now: now)
    }

    /// A scene went to the background or closed.
    func left(scene: UUID) {
        _ = scenes.left(scene)
    }

    /// What a modifier with this key shows: nothing without one, whatever was saved.
    func result(for key: String) -> TaoolUpdates.CheckResult {
        key.isEmpty ? .init() : result
    }

    /// `TaoolUpdates.status`: taool asked when it's due, whatever the scenes.
    func status(key: String, bundleID: String?) async -> UpdateStatus {
        await ask(key: key, bundleID: bundleID)
        return result(for: key).status
    }

    /// The app's server refused this version with a 426: taool asked at once, even if it answered recently, for the
    /// update screen's version and link, since the 426 already decided it shows. Once a launch, unless taool has never
    /// answered for the app (offline, nothing kept), when the next 426 asks again.
    func serverRequired(key: String, bundleID: String?) async {
        guard !askedForRequirement, let bundleID = TaoolUpdates.bundleToCheck(key: key, bundleID: bundleID) else { return }
        let platform = TaoolUpdates.platform
        show(await checker.policy(key: key, bundleID: bundleID, platform: platform, force: true))
        askedForRequirement = await checker.hasAnswer(key: key, bundleID: bundleID, platform: platform)
    }

    /// taool asked when it's due, and its answer shown; nothing without a key.
    private func ask(key: String, bundleID: String?, now: Date = .now) async {
        guard let bundleID = TaoolUpdates.bundleToCheck(key: key, bundleID: bundleID) else { return }
        show(await checker.policy(key: key, bundleID: bundleID, platform: TaoolUpdates.platform, now: now))
    }

    /// An answer taool gave (or the saved one, when it couldn't be reached), which settles the launch.
    func show(_ policy: UpdatePolicy?) {
        var next = TaoolUpdates.result(from: policy)
        next.isSettled = true
        if next != result { result = next }
    }
}

/// Whether the developer's own server has refused this version with a 426, this launch.
@MainActor
@Observable
final class ServerRequirement {
    static let shared = ServerRequirement()
    /// The 426s this launch: each one may ask taool again (`UpdateState.serverRequired`).
    private(set) var refusals = 0
    var isRequired: Bool { refusals > 0 }

    func require() { refusals += 1 }
}

/// What update prompts and What's New remember on the device: the version whose banner was closed, so it doesn't come
/// back every launch, the newest whose What's New page has shown, so each version's shows once, and when the user first
/// got the app.
@MainActor
@Observable
final class PromptMemory {
    static let shared = PromptMemory()

    struct Kept: FileState, Equatable {
        var closedBanner: String?
        var whatsNewShown: String?
        var firstDownloaded: Date?
    }

    private(set) var kept: Kept
    /// A simulated banner closed this launch, which comes back at the next, so it can be tried again.
    private var simulationClosed = false
    private let file: StateFile<Kept>

    init(file: StateFile<Kept> = .inAppSupport("updates-seen.json")) {
        self.file = file
        kept = file.read() ?? Kept()
    }

    func isClosed(_ offer: BannerOffer) -> Bool {
        offer.isSimulated ? simulationClosed : offer.release.version == kept.closedBanner
    }

    func close(_ offer: BannerOffer) {
        if offer.isSimulated { simulationClosed = true } else { keep { $0.closedBanner = offer.release.version } }
    }

    /// Marked once its page has loaded, by version rather than page, so a page uploaded again for its version, or an
    /// older page live again once a newer one is deleted, isn't shown again; never back to an older version, which
    /// `showWhatsNew()` may show.
    func shown(_ page: WhatsNewPage) {
        if page.isNewer(than: kept.whatsNewShown) { keep { $0.whatsNewShown = page.version } }
    }

    /// When this user first got the app, as StoreKit says, kept once known, so a launch StoreKit can't answer knows too.
    func firstDownloaded() async -> Date? {
        if let date = await AppTransactionFacts.read()?.downloadedAt, date != kept.firstDownloaded { keep { $0.firstDownloaded = date } }
        return kept.firstDownloaded
    }

    private func keep(_ change: (inout Kept) -> Void) {
        change(&kept)
        file.write(kept)
    }
}

/// Fetches and remembers policies. Each app launch asks taool once, then at most once an hour (`RefreshSchedule`); the
/// answer is kept on the device, shown before taool answers and when it can't be reached. Checks at the same moment
/// share one request.
actor UpdateChecker {
    static let shared = UpdateChecker()

    /// The answers kept, by app, platform and key.
    struct Kept: FileState {
        var policies: [String: Saved] = [:]
    }

    struct Saved: Codable, Sendable {
        let policy: UpdatePolicy?
        let fetchedAt: Date
    }

    private let session: URLSession
    private let baseURL: URL
    private let file: StateFile<Kept>
    /// Read once, written as it changes.
    private var kept: Kept
    /// The answer kept last when TaoolKit started, whichever app and key: what a launch shows before any modifier has
    /// said which (the app's own, unless a debug build passes another bundle ID).
    nonisolated let savedAtLaunch: UpdatePolicy?
    /// When each policy was last asked for this launch, whatever came of it.
    private var askedAt: [String: Date] = [:]
    /// Requests under way, which a check at the same moment waits for.
    private var asking: [String: Task<UpdatePolicy?, Never>] = [:]
    private let log = Logger(subsystem: "TaoolKit", category: "updates")

    init(session: URLSession = Kit.session, baseURL: URL = Kit.baseURL, file: StateFile<Kept> = .standard) {
        self.session = session
        self.baseURL = baseURL
        self.file = file
        let kept = file.read() ?? Kept()
        self.kept = kept
        savedAtLaunch = kept.policies.values.max { $0.fetchedAt < $1.fetchedAt }?.policy
    }

    /// taool has answered for this app, platform and key, now or at an earlier launch, even that it has no policy.
    func hasAnswer(key: String, bundleID: String, platform: String) -> Bool {
        kept.policies[Self.id(key: key, bundleID: bundleID, platform: platform)] != nil
    }

    private static func id(key: String, bundleID: String, platform: String) -> String { "\(bundleID) \(platform) \(key)" }

    /// Nil when taool has no policy for this app and key (or never answered). `force` asks
    /// even when taool answered recently.
    func policy(key: String, bundleID: String, platform: String, force: Bool = false, now: Date = .now) async -> UpdatePolicy? {
        let id = Self.id(key: key, bundleID: bundleID, platform: platform)
        // Forced too: a request that just started is as fresh as a new one.
        if let request = asking[id] { return await request.value }
        let saved = kept.policies[id]
        if !force, !RefreshSchedule.isDue(askedAt: askedAt[id], fetchedAt: saved?.fetchedAt, now: now) { return saved?.policy }

        askedAt[id] = now
        let request = Task {
            do {
                let policy = try await fetch(key: key, bundleID: bundleID, platform: platform)
                kept.policies[id] = Saved(policy: policy, fetchedAt: now)
                file.write(kept)
                return policy
            } catch {
                log.info("Update check failed, using the last answer: \(error.localizedDescription, privacy: .public)")
                return saved?.policy
            }
        }
        asking[id] = request
        let policy = await request.value
        asking[id] = nil
        return policy
    }

    private func fetch(key: String, bundleID: String, platform: String) async throws -> UpdatePolicy? {
        var url = baseURL.appending(path: "v1/updates/\(bundleID)/\(platform)")
        url.append(queryItems: [URLQueryItem(name: "key", value: key)])
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            return try Kit.decoder.decode(UpdatePolicy.self, from: data)
        case 404:
            Notice.once("taool has no update policy for \(bundleID) (\(platform)). Is it one of your apps in taool, and is the key right?", log: log)
            return nil
        default:
            throw URLError(.badServerResponse)
        }
    }
}

extension StateFile where State == UpdateChecker.Kept {
    static var standard: StateFile { inAppSupport("updates.json") }
}

/// What this install is.
enum Device {
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "This app"
    }
}
