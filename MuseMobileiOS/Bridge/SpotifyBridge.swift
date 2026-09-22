import Foundation
import WebKit

/// Native side of `window.AndBridge.*`. Single WKScriptMessageHandler named
/// "AndBridge" receiving {method, args}. Method names identical to Android
/// `SpotifyBridge` @JavascriptInterface surface.
public final class SpotifyBridge: NSObject {
    public weak var webView: WKWebView?
    public var onLoginDetected: (() -> Void)?
    public var onPlayLoaded: (() -> Void)?
    public var onMediaStatus: ((MediaStatus) -> Void)?
    public var onMediaPosition: ((Int64) -> Void)?
    public var onTimerDialog: (() -> Void)?
    public var onEnterPip: (() -> Void)?
    public var onEnterPipVideo: ((Int, Int) -> Void)?
    public var onDownloadTrack: ((String) -> Void)?
    public var onDownloadCollection: ((String) -> Void)?

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = Constants.sharedRequestTimeout
        c.timeoutIntervalForResource = Constants.sharedResourceTimeout
        c.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: c)
    }()

    public struct MediaStatus: Decodable {
        public var artist, track: String?
        public var playing: Bool?
        public var repeatMode: String?
        public var fav, shuffle: Bool?
        public var duration, position: Int64?
        public var cover: String?
        enum CodingKeys: String, CodingKey {
            case artist, track, playing, fav, shuffle, duration, position, cover
            case repeatMode = "repeat"
        }
    }

    func handle(method: String, args: [Any]) {
        switch method {
        case "loginDetected":
            UserDefaults.standard.set(true, forKey: AppSettings.Key.loggedIn.rawValue)
            DispatchQueue.main.async { self.onLoginDetected?() }
        case "deferMessage":
            let msg = (args.first as? String) ?? ""
            if msg == "adblock" { return } // silent
            DispatchQueue.main.async { ToastCenter.show(msg == "unlock" ? "Player unlocked" : msg) }
        case "cssInjected", "wakeUp", "wakeOff", "manageTShut", "manageTSleep":
            break // stubs (Android no-ops)
        case "dbg":
            guard AppSettings.bool(.debugOverlay) else { return }
            DebugLogStore.log("\(args.first ?? "")", "\(args.dropFirst().first ?? "")")
        case "recAdContentIds":
            if let json = args.first as? String,
               let data = json.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                AdIdStore.shared.addAll(arr)
            }
        case "playLoaded":
            DispatchQueue.main.async { self.onPlayLoaded?() }
        case "recMediaPosition":
            let pos: Int64 = (args.first as? NSNumber)?.int64Value ?? 0
            DispatchQueue.main.async { self.onMediaPosition?(pos) }
            NowPlayingManager.shared.updatePosition(pos)
        case "recMediaStatus":
            if let json = args.first as? String, let data = json.data(using: .utf8) {
                if let st = try? JSONDecoder().decode(MediaStatus.self, from: data) {
                    DispatchQueue.main.async { self.onMediaStatus?(st) }
                    NowPlayingManager.shared.update(from: json)
                }
            }
        case "onMediaItemsLoaded":
            CarPlayManager.shared.didLoadItems(parentId: args.first as? String ?? "", json: args.dropFirst().first as? String ?? "[]")
        case "onSearchCompleted":
            CarPlayManager.shared.didCompleteSearch(query: args.first as? String ?? "", json: args.dropFirst().first as? String ?? "[]")
        case "recAccountName":
            let name = ((args.first as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { UserDefaults.standard.set(name, forKey: AppSettings.Key.currentAccountName.rawValue) }
        case "openTimerDialog": DispatchQueue.main.async { self.onTimerDialog?() }
        case "enterPip": DispatchQueue.main.async { self.onEnterPip?() }
        case "enterPipVideo":
            let w = (args.first as? NSNumber)?.intValue ?? 0
            let h = (args.dropFirst().first as? NSNumber)?.intValue ?? 0
            DispatchQueue.main.async { self.onEnterPipVideo?(w, h) }
        case "downloadTrack": if let j = args.first as? String { onDownloadTrack?(j) }
        case "downloadCollection": if let j = args.first as? String { onDownloadCollection?(j) }
        case "skipDownload": DownloadManager.shared.skipCurrent()
        case "cancelDownload": DownloadManager.shared.cancelAll()
        case "nFetch":
            // args: url, optsJson, resolverId
            let url = args.first as? String ?? ""
            let opts = args.dropFirst().first as? String ?? "{}"
            let rid = args.dropFirst(2).first as? String ?? ""
            Task { await self.nFetch(urlString: url, optsJson: opts, resolverId: rid) }
        default: break
        }
    }

    // MARK: - nFetch (synchronous Spotify-API fetch w/ cookie sync, desktop headers)

    private func nFetch(urlString: String, optsJson: String, resolverId: String) async {
        let result = await fetchSync(urlString: urlString, optsJson: optsJson)
        let escaped = result
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let js = "(function(){var r=window.__splNFetchResolvers||{};var f=r['\(resolverId)'];if(f){delete r['\(resolverId)'];try{f('\(escaped)');}catch(e){}}})();"
        // Note: result is a JSON string of {status,body,headers}; resolve raw.
        let raw = result.replacingOccurrences(of: "`", with: "\\`")
        let js2 = "(function(){var r=window.__splNFetchResolvers||{};var f=r['\(resolverId)'];if(f){delete r['\(resolverId)'];try{f(`\(raw)`);}catch(e){}}})();"
        _ = js; await MainActor.run { self.webView?.evaluateJavaScript(js2, completionHandler: nil) }
    }

    func fetchSync(urlString: String, optsJson: String) async -> String {
        func err(_ e: Error) -> String {
            let o: [String: Any] = ["status": 0, "body": "\(e)", "headers": [:]]
            return (try? String(data: JSONSerialization.data(withJSONObject: o), encoding: .utf8)) ?? "{\"status\":0,\"body\":\"error\",\"headers\":{}}"
        }
        guard let url = URL(string: urlString) else { return err(URLError(.badURL)) }
        var method = "GET", body: String? = nil, headers: [String: String] = [:]
        if let data = optsJson.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            method = (obj["method"] as? String) ?? "GET"
            body = obj["body"] as? String
            headers = (obj["headers"] as? [String: String]) ?? [:]
        }
        let filtered: Set<String> = ["x-requested-with", "sec-ch-ua-full-version-list",
            "sec-ch-ua-platform-version", "sec-ch-ua-arch", "sec-ch-ua-bitness", "sec-ch-ua-model"]
        var req = URLRequest(url: url, timeoutInterval: Constants.nFetchConnectTimeout)
        req.httpMethod = method
        for (k, v) in headers where !filtered.contains(k.lowercased()) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(Constants.desktopUA, forHTTPHeaderField: "User-Agent")
        req.setValue("\"Windows\"", forHTTPHeaderField: "sec-ch-ua-platform")
        req.setValue("?0", forHTTPHeaderField: "sec-ch-ua-mobile")
        req.setValue(Constants.secCHUA, forHTTPHeaderField: "sec-ch-ua")
        if urlString.contains("spclient.spotify.com") || urlString.contains("scdn.co") || urlString.contains("spotify.com") {
            req.setValue(Constants.origin, forHTTPHeaderField: "Origin")
            req.setValue(Constants.origin + "/", forHTTPHeaderField: "Referer")
        }
        // Cookie sync from WKWebView store
        if let wv = webView {
            let cookies = await wv.configuration.websiteDataStore.httpCookieStore.allCookiesAsync()
            let jar = cookies.filter { url.host?.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) ?? false }
            if !jar.isEmpty {
                req.setValue(jar.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
            }
        }
        if let body, !body.isEmpty { req.httpBody = body.data(using: .utf8) }
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // Set-Cookie sync back into WebView
            if let http = resp as? HTTPURLResponse, let wv = webView {
                for (k, v) in http.allHeaderFields where "\(k)".lowercased() == "set-cookie" {
                    for part in ("\(v)".components(separatedBy: ",")) {
                        if let c = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": part], for: url).first {
                            await wv.configuration.websiteDataStore.httpCookieStore.setCookieAsync(c)
                        }
                    }
                }
            }
            var capped = data
            if capped.count > Constants.nFetchBodyCap { capped = capped.prefix(Constants.nFetchBodyCap) }
            let bodyStr = String(data: capped, encoding: .utf8) ?? ""
            var h: [String: String] = [:]
            if let http = resp as? HTTPURLResponse {
                for (k, v) in http.allHeaderFields { h["\(k)"] = "\(v)" }
            }
            let o: [String: Any] = ["status": code, "body": bodyStr, "headers": h]
            return String(data: try JSONSerialization.data(withJSONObject: o), encoding: .utf8) ?? ""
        } catch {
            return err(error)
        }
    }
}

// MARK: - WKHTTPCookieStore async wrappers (callback API has no async variant)

extension WKHTTPCookieStore {
    func allCookiesAsync() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            getAllCookies { cont.resume(returning: $0) }
        }
    }
    func setCookieAsync(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { cont in
            setCookie(cookie) { cont.resume() }
        }
    }
}
