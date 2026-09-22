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
        config.preferences.javaScriptEnabled = true
        // AndBridge handler
        config.userContentController.add(context.coordinator, name: "AndBridge")
        // Bridge shim at document start (bundled flat, no folder reference)
        if let shimURL = Bundle.main.url(forResource: "__BridgeShim", withExtension: "js"),
           let shim = try? String(contentsOf: shimURL) {
            config.userContentController.addUserScript(
                WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
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
        observeLifecycle(coordinator)
        return wv
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}

    private func observeLifecycle(_ c: Coordinator) {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            c.webView?.evaluateJavaScript("window.__splBg=true;", completionHandler: nil)
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            c.webView?.evaluateJavaScript("window.__splBg=false;", completionHandler: nil)
        }
    }

    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let bridge: SpotifyBridge
        var onNavigate: ((Bool) -> Void)?
        weak var webView: WKWebView?
        init(bridge: SpotifyBridge, onNavigate: ((Bool) -> Void)?) { self.bridge = bridge; self.onNavigate = onNavigate }

        // MARK: message handler
        public func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard m.name == "AndBridge",
                  let d = m.body as? [String: Any],
                  let method = d["method"] as? String else { return }
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
            decisionHandler(.allow)
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
