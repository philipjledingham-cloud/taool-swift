// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import SwiftUI
import TaoolCore

extension View {
    /// Update prompts: a banner at the top when an update is available, which can be dismissed
    /// for that version, and a screen covering the app when this version must update, or when
    /// your server said so with a 426 (`TaoolUpdates.serverRequiredUpdate()`). What the device
    /// last heard shows from the first frame, worked out against the version running, so an
    /// update installed never shows a prompt; as the app comes to the foreground it asks taool
    /// (TaoolUpdates spaces the requests out) and changes only if the answer differs. Put it on
    /// the root view of each scene, and of each full-screen cover or sheet users can't close (a
    /// hard paywall, onboarding), which would otherwise sit above the screen. With
    /// `.taoolWhatsNew(key:)` as well, the two share one check.
    ///
    /// - Parameters:
    ///   - key: The account's key, from the taool app's TaoolKit page. Public: it's fine to ship in the app.
    ///   - placement: Where the banner shows: at the top or the bottom, the app's content moving aside
    ///     for it, or `.inline`, only where you put `TaoolUpdates.Banner()`.
    ///   - bundleID: The App Store app's bundle ID, when a debug build uses a different one.
    ///   - simulating: Shows a fake status in DEBUG builds, to try out the UI.
    public func taoolUpdatePrompts(key: String, placement: UpdateBannerPlacement = .top, bundleID: String? = nil,
                                   simulating simulation: UpdateSimulation? = nil) -> some View {
        modifier(UpdatePromptsModifier(key: key, bundleID: bundleID, placement: placement, simulation: simulation))
    }
}

/// Where update prompts' banner shows.
public enum UpdateBannerPlacement: Sendable {
    /// At the top, over a navigation bar there, the app's content moving down for it.
    case top
    /// At the bottom, over a tab bar or toolbar there, the app's content moving up for it.
    case bottom
    /// Only where you put `TaoolUpdates.Banner()`, such as the top of a home screen's scroll view,
    /// scrolling with it rather than staying over the app.
    case inline

    var edge: VerticalEdge? {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .inline: nil
        }
    }
}

extension TaoolUpdates {
    /// Update prompts' banner where you put it, with `.taoolUpdatePrompts(key:placement: .inline)` on the root
    /// view around it, which checks and tells it what to show. Nothing until an update is available, nor once
    /// it's closed for that version or the update screen covers the app. Put it where users look first, such as
    /// the top of a home screen's scroll view; it's as wide as you give it, with no padding of its own.
    ///
    /// ```swift
    /// ScrollView {
    ///     TaoolUpdates.Banner()
    ///     …
    /// }
    /// ```
    ///
    /// Or in your own design: TaoolKit still decides when it shows and what it says (translated, or your
    /// messages from the taool app), and opens the App Store and remembers the close for you.
    ///
    /// ```swift
    /// TaoolUpdates.Banner { update in
    ///     MyCard {
    ///         Text(update.title).font(.headline)
    ///         Text(update.message)
    ///         Button(update.button, action: update.open)
    ///         Button(update.notNow, action: update.dismiss)
    ///     }
    /// }
    /// ```
    public struct Banner<Content: View>: View {
        @Environment(\.taoolUpdateOffer) private var offer
        @Environment(\.openURL) private var openURL
        /// Nil: TaoolKit's own banner.
        private let content: ((BannerUpdate) -> Content)?

        /// The banner in your own design, from what `update` says and does.
        public init(@ViewBuilder content: @escaping (BannerUpdate) -> Content) {
            self.content = content
        }

        public var body: some View {
            if let offer {
                let dismiss = { withAnimation { PromptMemory.shared.close(offer) } }
                if let content {
                    content(BannerUpdate(offer: offer, open: { openURL(offer.release.appStoreURL) }, dismiss: dismiss))
                } else {
                    UpdateBanner(release: offer.release, edge: nil, text: offer.text, notNow: offer.notNow, dismiss: dismiss)
                }
            }
        }
    }

    /// What a banner of your own design shows and does (`TaoolUpdates.Banner { update in … }`): TaoolKit's
    /// words, in your app's language or the one locked in the taool app, or your own message from it.
    public struct BannerUpdate {
        /// "Update Available".
        public let title: String
        /// "Version 2.0 is on the App Store.", or your message for it from the taool app.
        public let message: String
        /// The label for the button that opens the App Store: "Update".
        public let button: String
        /// The label for the button that closes the banner: "Not Now".
        public let notNow: String
        /// The version to update to: "2.0".
        public let version: String
        private let openAction: () -> Void
        private let dismissAction: () -> Void

        init(offer: BannerOffer, open: @escaping () -> Void, dismiss: @escaping () -> Void) {
            title = offer.text.title
            message = offer.text.message
            button = offer.text.button
            notNow = offer.notNow
            version = offer.release.version
            openAction = open
            dismissAction = dismiss
        }

        /// Opens the app's page in the App Store. The banner stays until the app is updated or closed.
        public func open() { openAction() }

        /// Closes the banner for this version: it's back only for a newer one.
        public func dismiss() { dismissAction() }
    }
}

extension TaoolUpdates.Banner where Content == EmptyView {
    /// TaoolKit's own banner.
    public init() {
        content = nil
    }
}

/// The banner's update and what it says.
struct BannerOffer: Equatable, Sendable {
    let release: AppRelease
    let text: UpdatePromptText
    let notNow: String
    /// A simulated update, whose close lasts only until the app is launched again.
    let isSimulated: Bool
}

extension EnvironmentValues {
    /// What `TaoolUpdates.Banner` shows, from `.taoolUpdatePrompts(key:placement: .inline)` around it.
    @Entry var taoolUpdateOffer: BannerOffer? = nil
}

struct UpdatePromptsModifier: ViewModifier {
    let key: String
    let bundleID: String?
    let placement: UpdateBannerPlacement
    let simulation: UpdateSimulation?

    private var requirement: ServerRequirement { .shared }

    /// Every scene's answer (`UpdateState`): the status, the App Store link for the screen after a 426 when taool hasn't
    /// named a newer version, and what the prompts say; none without a key. In DEBUG, a simulated one instead.
    private var shown: TaoolUpdates.CheckResult {
        #if DEBUG
        if let simulation { return TaoolUpdates.CheckResult(status: simulation.status) }
        #endif
        return UpdateState.shared.result(for: key)
    }

    func body(content: Content) -> some View {
        let shown = shown
        let status = shown.status, wording = shown.wording
        let cover = UpdateCover(status: status, serverRequired: requirement.isRequired, appStoreURL: shown.appStoreURL)
        // Never while the update screen covers the app.
        let banner = cover == nil ? available(status, wording: wording) : nil
        content
            .environment(\.taoolUpdateOffer, placement == .inline ? banner : nil)
            .safeAreaInset(edge: placement.edge ?? .top) {
                if let edge = placement.edge, let banner {
                    UpdateBanner(release: banner.release, edge: edge, text: banner.text, notNow: banner.notNow) {
                        withAnimation { PromptMemory.shared.close(banner) }
                    }
                }
            }
            .overlay {
                if let cover { UpdateRequiredView(cover: cover, text: wording.text(for: cover)) }
            }
            .animation(.default, value: cover)
            .animation(.default, value: status)
            .updateSceneUse(key: key, bundleID: bundleID)
            // Each 426, which asks taool again only while it has never answered.
            .task(id: requirement.refusals) {
                if requirement.isRequired { await UpdateState.shared.serverRequired(key: key, bundleID: bundleID) }
            }
    }

    /// The banner's update and text, when an update is available and its banner wasn't closed.
    private func available(_ status: UpdateStatus, wording: UpdateWording) -> BannerOffer? {
        guard case .available(let release) = status else { return nil }
        #if DEBUG
        let isSimulated = simulation != nil
        #else
        let isSimulated = false
        #endif
        let offer = BannerOffer(release: release, text: wording.text(.available, version: release.version),
                                notNow: wording.strings["banner.notNow"], isSimulated: isSimulated)
        return PromptMemory.shared.isClosed(offer) ? nil : offer
    }
}

extension View {
    /// Tells `UpdateState` as this scene becomes active and leaves, for both modifiers, which make one check.
    func updateSceneUse(key: String, bundleID: String?) -> some View {
        modifier(SceneUse { await UpdateState.shared.becameActive(scene: $0, key: key, bundleID: bundleID) } left: {
            UpdateState.shared.left(scene: $0)
        })
    }
}

/// What covers the app: taool's own answer, or a 426 from the developer's server
/// (`TaoolUpdates.serverRequiredUpdate()`), which covers it whatever taool last said.
enum UpdateCover: Equatable {
    /// Update to `release`, or with no newer version known, to whatever the App Store has.
    case required(AppRelease?, appStoreURL: URL?)
    /// This version must update, and no version that would do runs on this OS.
    case unsupported(requiredOSVersion: String?)

    init?(status: UpdateStatus, serverRequired: Bool, appStoreURL: URL?) {
        switch status {
        case .required(let release): self = .required(release, appStoreURL: release.appStoreURL)
        case .unsupported(let os): self = .unsupported(requiredOSVersion: os)
        // The server refused this version: the newest one this device can install, when taool knows one.
        case .available(let release) where serverRequired: self = .required(release, appStoreURL: release.appStoreURL)
        case .current where serverRequired: self = .required(nil, appStoreURL: appStoreURL)
        case .current, .available: return nil
        }
    }
}

/// "Update Available", with the version or the developer's message, and a button to the App Store.
struct UpdateBanner: View {
    let release: AppRelease
    /// The edge it shows at, which it slides in from; nil where `TaoolUpdates.Banner` is.
    let edge: VerticalEdge?
    let text: UpdatePromptText
    /// The close button's accessibility label.
    let notNow: String
    let dismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        UpdateBannerContent(text: text, notNow: notNow, update: { openURL(release.appStoreURL) }, dismiss: dismiss)
            .padding(edge == nil ? [] : .horizontal)
            .padding(edge == .top ? .top : .bottom, edge == nil ? 0 : 8)
            .transition(edge.map { .move(edge: $0 == .top ? .top : .bottom).combined(with: .opacity) } ?? .opacity)
            .accessibilityElement(children: .contain)
    }
}

/// The banner itself, for `UpdateBanner` and `TaoolUpdates.Banner`.
struct UpdateBannerContent: View {
    let text: UpdatePromptText
    /// The close button's accessibility label.
    let notNow: String
    let update: () -> Void
    let dismiss: () -> Void
    @Environment(\.taoolTint) private var tint

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(tint.fill)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title).font(.headline)
                Text(text.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            AccentButton(action: update) { Text(text.button) }
                .buttonBorderShape(.capsule)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(notNow)
        }
        .padding(12)
        .bannerBackground()
    }
}

/// Covers the app when this version must update: why, and the App Store button. With no
/// version to update to on this OS, it says which OS one needs.
struct UpdateRequiredView: View {
    let cover: UpdateCover
    let text: UpdatePromptText
    @Environment(\.openURL) private var openURL
    @Environment(\.taoolUpdateRequiredScreen) private var customScreen

    var body: some View {
        let required = TaoolUpdates.RequiredUpdate(text: text, cover: cover, open: update)
        Group {
            if let customScreen {
                customScreen.make(required)
            } else {
                UpdateRequiredContent(text: text, isUnsupported: required.isUnsupported, update: update)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Behind a screen of the app's own too, so the app never shows through a transparent one.
        .background(.background)
        .accessibilityAddTraits(.isModal)
    }

    /// Nothing to open with no version for this OS, or no App Store link yet.
    private var update: (() -> Void)? {
        guard case .required(_, let appStoreURL?) = cover else { return nil }
        return { openURL(appStoreURL) }
    }
}

extension View {
    /// The update-required screen in your own design, for every `.taoolUpdatePrompts` inside it: put it once,
    /// after the modifiers on the root view, as `.taoolTint` is. TaoolKit still decides when it covers the app
    /// (below your minimum, after your server's 426, or when no version runs on this OS) and what it says,
    /// translated or your messages from the taool app; it lays your screen over the whole window, with a plain
    /// background behind it, and there's no closing it.
    ///
    /// ```swift
    /// ContentView()
    ///     .taoolUpdatePrompts(key: "taool_public_…")
    ///     .taoolUpdateRequiredScreen { required in
    ///         MyScreen {
    ///             Text(required.title)
    ///             Text(required.message)
    ///             if let button = required.button {
    ///                 Button(button, action: required.open)
    ///             }
    ///         }
    ///     }
    /// ```
    public func taoolUpdateRequiredScreen<Screen: View>(@ViewBuilder _ screen: @escaping (TaoolUpdates.RequiredUpdate) -> Screen) -> some View {
        environment(\.taoolUpdateRequiredScreen, RequiredScreen { AnyView(screen($0)) })
    }
}

extension TaoolUpdates {
    /// What an update-required screen of your own design shows and does (`.taoolUpdateRequiredScreen`):
    /// TaoolKit's words, in your app's language or the one locked in the taool app, or your own message from it.
    public struct RequiredUpdate {
        /// "Update Required", or when no version runs on this OS, "Update Not Available".
        public let title: String
        /// Why, with the version to update to, or the OS a version that would do needs; or your message for it from the taool app.
        public let message: String
        /// The label for the button that opens the App Store: "Update". Nil when there's nothing to install,
        /// since no version runs on this OS, or before taool has said where the app is on the App Store: show no button then.
        public let button: String?
        /// No version at or above your minimum runs on this OS: the user has to update the OS first.
        public let isUnsupported: Bool
        /// The version to update to, when it's known: "2.0".
        public let version: String?
        private let openAction: (() -> Void)?

        init(text: UpdatePromptText, cover: UpdateCover, open: (() -> Void)?) {
            title = text.title
            message = text.message
            button = open == nil ? nil : text.button
            switch cover {
            case .required(let release, _):
                isUnsupported = false
                version = release?.version
            case .unsupported:
                isUnsupported = true
                version = nil
            }
            openAction = open
        }

        /// Opens the app's page in the App Store, when there's a `button`.
        public func open() { openAction?() }
    }
}

/// `.taoolUpdateRequiredScreen`'s screen, in a struct since `@Entry` warns of a bare closure, which never compares equal.
struct RequiredScreen: Sendable {
    let make: @MainActor (TaoolUpdates.RequiredUpdate) -> AnyView
}

extension EnvironmentValues {
    @Entry var taoolUpdateRequiredScreen: RequiredScreen? = nil
}

/// The update-required screen's content.
struct UpdateRequiredContent: View {
    let text: UpdatePromptText
    let isUnsupported: Bool
    /// Nil: no button.
    let update: (() -> Void)?
    @Environment(\.taoolTint) private var tint

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: isUnsupported ? "exclamationmark.triangle.fill" : "arrow.down.app.fill")
                .font(.system(size: 56))
                .foregroundStyle(tint.fill)
                .accessibilityHidden(true)
            Text(text.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(text.message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let update {
                AccentButton(action: update) {
                    Text(text.button).frame(maxWidth: 360)
                }
                .controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: 520)
    }
}

extension Device {
    /// iOS, iPadOS or macOS, as the update-not-available screen names the OS to update.
    @MainActor static var osName: String {
        RunningApp.platform == "macos" ? "macOS" : RunningApp.deviceKind == "pad" ? "iPadOS" : "iOS"
    }
}

private extension View {
    /// Liquid Glass where the OS has it, a material before that.
    @ViewBuilder func bannerBackground() -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: 20))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

#Preview("Available") {
    Text("Your app").frame(maxWidth: .infinity, maxHeight: .infinity)
        .taoolUpdatePrompts(key: "", simulating: .available)
}

#Preview("Available at the bottom") {
    Text("Your app").frame(maxWidth: .infinity, maxHeight: .infinity)
        .taoolUpdatePrompts(key: "", placement: .bottom, simulating: .available)
}

#Preview("Available inline") {
    ScrollView {
        VStack(spacing: 16) {
            TaoolUpdates.Banner()
            Text("Your app")
        }
        .padding()
    }
    .taoolUpdatePrompts(key: "", placement: .inline, simulating: .available)
}

#Preview("Available inline, own design") {
    ScrollView {
        VStack(spacing: 16) {
            TaoolUpdates.Banner { update in
                VStack(alignment: .leading, spacing: 8) {
                    Text(update.title).font(.headline)
                    Text(update.message).foregroundStyle(.secondary)
                    HStack {
                        Button(update.button, action: update.open).buttonStyle(.borderedProminent)
                        Button(update.notNow, action: update.dismiss)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.yellow.opacity(0.2), in: .rect(cornerRadius: 12))
            }
            Text("Your app")
        }
        .padding()
    }
    .taoolUpdatePrompts(key: "", placement: .inline, simulating: .available)
}

#Preview("Required") {
    Text("Your app").taoolUpdatePrompts(key: "", simulating: .required)
}

#Preview("Unsupported") {
    Text("Your app").taoolUpdatePrompts(key: "", simulating: .unsupported)
}

#Preview("Required, own design") {
    Text("Your app").taoolUpdatePrompts(key: "", simulating: .required)
        .taoolUpdateRequiredScreen { required in
            VStack(spacing: 12) {
                Text(required.title).font(.largeTitle.bold())
                Text(required.message).multilineTextAlignment(.center)
                if let button = required.button {
                    Button(button, action: required.open).buttonStyle(.borderedProminent)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.yellow.opacity(0.2))
        }
}

#Preview("Tinted") {
    Text("Your app").frame(maxWidth: .infinity, maxHeight: .infinity)
        .taoolUpdatePrompts(key: "", simulating: .available)
        .taoolTint(.yellow)
}
