import Foundation
import WebKit
import SwiftUI
import UIKit

/// WKWebView host. Mirrors Android MainActivity WebView config + SpotifyWebViewClient:
/// desktop UA + client hints, autoplay without gesture, no file/geolocation access,
/// black background, multi-window gated to Spotify/OAuth hosts, inspectable in DEBUG.
public struct SpotifyWebView: UIViewRepresentable {
    public var bridge: SpotifyBridge
    public var onNavigate: ((Bool) -> Void)?

    public func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge, onNavigate: onNavigate) }

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        // AndBridge handler
        config.userContentController.add(context.coordinator, name: "AndBridge")
        // Bridge shim at document start (bundled flat, no folder reference)
        if let shimURL = Bundle.main.url(forResource: "__BridgeShim", withExtension: "js"),
           let shim = try? String(contentsOf: shimURL) {
            config.userContentController.addUserScript(
                WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = Constants.desktopUA
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.backgroundColor = .black
        wv.isOpaque = true
        #if DEBUG
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        #endif
        context.coordinator.webView = wv
        bridge.webView = wv
        // Entry URL by login state
        let loggedIn = AppSettings.bool(.loggedIn)
        wv.load(URLRequest(url: loggedIn ? Constants.spotifyHome : Constants.spotifyLogin))
        // Background parking hooks (__splBg + __splWas{ Pfint,Afint,Cssint })
        observeLifecycle(context.coordinator)
        return wv
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}

    public func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.removeLifecycleObservers()
    }

    private func observeLifecycle(_ c: Coordinator) {
        c.bgToken = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak c] _ in
            c?.webView?.evaluateJavaScript("window.__splBg=true;", completionHandler: nil)
        }
        c.fgToken = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak c] _ in
            c?.webView?.evaluateJavaScript("window.__splBg=false;", completionHandler: nil)
        }
    }

    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let bridge: SpotifyBridge
        var onNavigate: ((Bool) -> Void)?
        weak var webView: WKWebView?
        var bgToken: NSObjectProtocol?
        var fgToken: NSObjectProtocol?
        init(bridge: SpotifyBridge, onNavigate: ((Bool) -> Void)?) { self.bridge = bridge; self.onNavigate = onNavigate }

        deinit {
            removeLifecycleObservers()
        }

        func removeLifecycleObservers() {
            if let t = bgToken {
                NotificationCenter.default.removeObserver(t)
                bgToken = nil
            }
            if let t = fgToken {
                NotificationCenter.default.removeObserver(t)
                fgToken = nil
            }
        }

        // MARK: message handler
        public func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard m.name == "AndBridge",
                  let d = m.body as? [String: Any],
                  let method = d["method"] as? String else { return }
            // Frame-gate: only the main frame may drive privileged bridge methods
            // (nFetch, downloadTrack/Collection, loginDetected, recAdContentIds).
            // The shim is installed forMainFrameOnly:true, but defense-in-depth:
            // silently ignore messages posted from iframes/ad frames.
            guard m.frameInfo.isMainFrame == true else { return }
            bridge.handle(method: method, args: d["args"] as? [Any] ?? [])
        }

        // MARK: page start — flags + spoof + fetch/adblock stack
        public func webView(_ wv: WKWebView, didCommit nav: WKNavigation!) {
            AdIdStore.shared.clear()
            let url = wv.url?.absoluteString ?? ""
            let host = wv.url?.host ?? ""
            let isGoogle = AdBlocker.isGoogleAuth(host: host)
            let js = InjectionLoader.pageStartScript(
                useProxy: AppSettings.string(.connectionMode, default: "normal") == "proxy",
                powerSave: AppSettings.bool(.powerSave),
                hideEmpty: AppSettings.bool(.hideEmptyPlayer),
                isGoogleAuth: isGoogle)
            wv.evaluateJavaScript(js, completionHandler: nil)
            _ = url
        }

        // MARK: page finish — login router + player stack
        public func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
            onNavigate?(wv.canGoBack)
            guard let url = wv.url?.absoluteString else { return }
            if url.hasPrefix("https://www.facebook.com/privacy/consent/gdp/") {
                wv.evaluateJavaScript(InjectionLoader.jsResource("FbGdprBypass"), completionHandler: nil); return
            }
            if url.hasSuffix("/login") {
                wv.evaluateJavaScript(InjectionLoader.jsResource("ClassicLoginButton"), completionHandler: nil)
            }
            if !AppSettings.bool(.loggedIn) {
                wv.evaluateJavaScript(InjectionLoader.jsResource("LoginDetection"), completionHandler: nil); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                wv.evaluateJavaScript(InjectionLoader.playerScript(), completionHandler: nil)
            }
            wv.evaluateJavaScript(InjectionLoader.jsResource("LogoutCheck")) { res, _ in
                if (res as? String) == "out" {
                    UserDefaults.standard.set(false, forKey: AppSettings.Key.loggedIn.rawValue)
                    wv.load(URLRequest(url: Constants.spotifyLogin))
                }
            }
        }

        // MARK: adblock — analytics stub + ad-audio -> silent.mp3
        public func webView(_ wv: WKWebView, decidePolicyFor resp: WKNavigationResponse,
                            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard let url = resp.response.url?.absoluteString else { decisionHandler(.allow); return }
            // NOTE: analytics URLs are cancelled here (not answered with an
            // empty-200-with-CORS body like Android). WKNavigationResponsePolicy
            // cannot synthesize response bodies, and a custom URLSchemeHandler
            // would be too invasive for this scope; GaBlocker.js covers
            // fetch/XHR page-side so promises resolve instead of erroring.
            if AdBlocker.isAnalytics(url) { decisionHandler(.cancel); return }
            if AdIdStore.shared.matches(url) && !AdBlocker.isProtectedMusicURL(url) {
                bridge.handle(method: "deferMessage", args: ["adblock"])
                decisionHandler(.cancel); redirectToSilent(wv, original: url); return
            }
            let useProxy = AppSettings.string(.connectionMode, default: "normal") == "proxy"
            if useProxy, AdBlocker.matchAdCdn(url) != nil, !AdBlocker.isProtectedMusicURL(url) {
                bridge.handle(method: "deferMessage", args: ["adblock"])
                decisionHandler(.cancel); redirectToSilent(wv, original: url); return
            }
            decisionHandler(.allow)
        }

        private func redirectToSilent(_ wv: WKWebView, original: String) {
            // Audio element swap is handled page-side by Adblockify skip watchdog;
            // native cancel prevents the bytes. Full AVAssetResourceLoaderDelegate
            // redirect for <audio> lives in AudioResourceLoader (see Media/).
            _ = original
        }

        public func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction,
                            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Top-level navigation gating (phishing/adware protection):
            // only MAIN-frame navigations are allow-listed; sub-frame/resource
            // loads always pass through. open/accounts.spotify.com stay working
            // via the spotify.com suffix rule.
            if action.targetFrame?.isMainFrame == false {
                decisionHandler(.allow)
                return
            }
            guard let host = action.request.url?.host?.lowercased(), !host.isEmpty else {
                // No host (about:blank, data:, etc.) — allow so bootstrap isn't broken.
                decisionHandler(.allow)
                return
            }
            if Self.isAllowedTopLevelHost(host) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        private static let allowedTopLevelHosts = ["spotify.com", "google.com", "facebook.com", "youtube.com"]

        private static func isAllowedTopLevelHost(_ host: String) -> Bool {
            for base in allowedTopLevelHosts {
                if host == base || host.hasSuffix("." + base) { return true }
            }
            return false
        }

        // window.open gated to Spotify/OAuth hosts
        public func webView(_ wv: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                            for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let host = action.request.url?.host?.lowercased() else { return nil }
            let ok = host.contains("spotify.com") || host.contains("google.com") || host.contains("facebook.com")
            if ok { wv.load(action.request) }
            return nil
        }
    }
}
