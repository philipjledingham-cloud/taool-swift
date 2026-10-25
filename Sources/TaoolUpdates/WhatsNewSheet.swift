// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import SwiftUI
// Only so that on tvOS and watchOS, which have no WebKit, the build stops at TaoolUpdates' own error.
#if canImport(WebKit)
import WebKit
#endif

/// The app's What's New page in a sheet: the page itself, full bleed, a close button, and when
/// this build is older than the page's version, a bar with the App Store button. The page's own
/// links open outside the app (the App Store, a mailto:, a website), and a page that fails to
/// load closes the sheet rather than showing an error. It counts as shown once it has loaded.
struct WhatsNewSheet: View {
    let shown: PresentedWhatsNew

    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        let strings = UpdateStrings(language: shown.language)
        NavigationStack {
            WhatsNewWebView(url: shown.url, isLoading: $isLoading, openURL: openURL, onFail: { dismiss() })
                // On iOS up under the navigation bar too, so the page fills the sheet and the
                // close button floats over it; the web view keeps its content clear of the bar.
                #if os(iOS)
                .ignoresSafeArea()
                #else
                .ignoresSafeArea(edges: .bottom)
                #endif
                .overlay {
                    if isLoading { ProgressView().controlSize(.large) }
                }
                .onChange(of: isLoading) { PromptMemory.shared.shown(shown.page) }
                .safeAreaInset(edge: .bottom) {
                    if let version = shown.updateTo, let appStoreURL = shown.appStoreURL {
                        UpdateBar(version: version, strings: strings) { openURL(appStoreURL) }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(strings["whatsNew.close"], systemImage: "xmark") { dismiss() }
                    }
                }
                #if os(iOS)
                .toolbarBackground(.hidden, for: .navigationBar)
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 560, idealHeight: 720)
        #endif
    }
}

/// "Update to version 2.0 to get what's new." with an Update button.
private struct UpdateBar: View {
    let version: String
    let strings: UpdateStrings
    let update: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(strings.format("whatsNew.update", version))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            AccentButton(action: update) { Text(strings["button.update"]) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

/// The page in a web view that keeps nothing between visits: no cookies, storage or cache for the page to leave behind.
@MainActor
private struct WhatsNewWebView {
    let url: URL
    @Binding var isLoading: Bool
    let openURL: OpenURLAction
    let onFail: () -> Void

    func makeCoordinator() -> WhatsNewNavigation { WhatsNewNavigation(page: url, isLoading: $isLoading, openURL: openURL, onFail: onFail) }

    private func webView(delegate: WhatsNewNavigation) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = delegate
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return webView
    }
}

#if os(iOS)
extension WhatsNewWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let webView = webView(delegate: context.coordinator)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#elseif os(macOS)
extension WhatsNewWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let webView = webView(delegate: context.coordinator)
        webView.underPageBackgroundColor = .clear
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
#endif

/// Keeps the web view on the page's own folder: anything else, a website included, opens
/// outside the app, so the page never shows what taool didn't host.
private final class WhatsNewNavigation: NSObject, WKNavigationDelegate {
    private let folder: URL
    @Binding private var isLoading: Bool
    private let openURL: OpenURLAction
    private let onFail: () -> Void

    init(page: URL, isLoading: Binding<Bool>, openURL: OpenURLAction, onFail: @escaping () -> Void) {
        folder = page.deletingLastPathComponent()
        _isLoading = isLoading
        self.openURL = openURL
        self.onFail = onFail
    }

    @MainActor
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let isOwn = url.host() == folder.host() && url.path().hasPrefix(folder.path())
        // The page's own files and its anchors stay; the first load always does.
        if isOwn || action.targetFrame?.isMainFrame == false && url.scheme == "about" { return .allow }
        openURL(url)
        return .cancel
    }

    @MainActor
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            onFail()
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoading = false }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    /// Offline or gone, before it loaded or partway through: close, never counted as shown, so it's tried again at the
    /// next launch. Not for a load the page replaced with another.
    private func failed(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { onFail() }
    }
}
