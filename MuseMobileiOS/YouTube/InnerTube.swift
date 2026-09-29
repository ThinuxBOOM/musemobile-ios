import Foundation
import CryptoKit

/// InnerTube client. Mirrors Android innertube/ + YouTube.kt:
/// POST music.youtube.com/youtubei/v1/search|player, SAPISIDHASH login,
/// no disk cache (all POSTs), shared session 15s/30s, 8 conn/host, retry
/// transport-only x3 (500ms->1000ms backoff).
public final class InnerTube {
    public static let shared = InnerTube()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = Constants.sharedRequestTimeout
        c.timeoutIntervalForResource = Constants.sharedResourceTimeout
        c.httpMaximumConnectionsPerHost = 8
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    public struct Client: Codable {
        public var clientName, clientVersion: String
        public var clientId: Int
        public var userAgent: String
    }
    // Client chain toward Android YouTubeClient.kt + YTPlayerUtils
    // STREAM_FALLBACK_CLIENTS. Exact clientName/clientVersion/clientId/userAgent
    // copied from Android innertube/models/YouTubeClient.kt where noted.
    // Order: WEB_REMIX (main) then fallbacks TVHTML5_SIMPLY_EMBEDDED_PLAYER(85)
    // first for age-restricted, TVHTML5, ANDROID_VR 1.43.32, ANDROID_VR 1.61.48,
    // ANDROID_CREATOR, IPADOS, ANDROID_VR_NO_AUTH, MOBILE, IOS, WEB, WEB_CREATOR last.
    public static let clients: [Client] = [
        // Exact from Android WEB_REMIX (1.20260213.01.00, id 67, Firefox 140 UA).
        .init(clientName: "WEB_REMIX", clientVersion: "1.20260213.01.00", clientId: 67,
              userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"),
        // Exact from Android TVHTML5_SIMPLY_EMBEDDED_PLAYER (2.0, id 85, PS4 UA).
        .init(clientName: "TVHTML5_SIMPLY_EMBEDDED_PLAYER", clientVersion: "2.0", clientId: 85,
              userAgent: "Mozilla/5.0 (PlayStation; PlayStation 4/12.02) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Safari/605.1.15"),
        // Exact from Android TVHTML5 (7.20260213.00.00, id 7, Samsung TV UA).
        .init(clientName: "TVHTML5", clientVersion: "7.20260213.00.00", clientId: 7,
              userAgent: "Mozilla/5.0(SMART-TV; Linux; Tizen 4.0.0.2) AppleWebkit/605.1.15 (KHTML, like Gecko) SamsungBrowser/9.2 TV Safari/605.1.15"),
        // Exact from Android ANDROID_VR_1_43_32 (1.43.32, id 28).
        .init(clientName: "ANDROID_VR", clientVersion: "1.43.32", clientId: 28,
              userAgent: "com.google.android.apps.youtube.vr.oculus/1.43.32 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)"),
        // Exact from Android ANDROID_VR_1_61_48 (1.61.48, id 28).
        .init(clientName: "ANDROID_VR", clientVersion: "1.61.48", clientId: 28,
              userAgent: "com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)"),
        // Exact from Android ANDROID_CREATOR (25.03.101, id 14).
        .init(clientName: "ANDROID_CREATOR", clientVersion: "25.03.101", clientId: 14,
              userAgent: "com.google.android.apps.youtube.creator/25.03.101 (Linux; U; Android 15; en_US; Pixel 9 Pro Fold; Build/AP3A.241005.015.A2; Cronet/132.0.6779.0)"),
        // Exact from Android IPADOS (clientName IOS, 21.03.3, id 5).
        .init(clientName: "IOS", clientVersion: "21.03.3", clientId: 5,
              userAgent: "com.google.ios.youtube/21.03.3 (iPad7,6; U; CPU iPadOS 17_7_10 like Mac OS X; en-US)"),
        // Exact from Android ANDROID_VR_NO_AUTH (1.61.48, id 28, Oculus Quest 3 UA).
        .init(clientName: "ANDROID_VR", clientVersion: "1.61.48", clientId: 28,
              userAgent: "com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12; en_US; Oculus Quest 3; Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)"),
        // Exact from Android MOBILE (clientName ANDROID, 21.03.38, id 3).
        .init(clientName: "ANDROID", clientVersion: "21.03.38", clientId: 3,
              userAgent: "com.google.android.youtube/21.03.38 (Linux; U; Android 14) gzip"),
        // Exact from Android IOS (21.03.1, id 5).
        .init(clientName: "IOS", clientVersion: "21.03.1", clientId: 5,
              userAgent: "com.google.ios.youtube/21.03.1 (iPhone16,2; U; CPU iOS 18_2 like Mac OS X;)"),
        // Exact from Android WEB (2.20260213.00.00, id 1, Firefox 140 UA).
        .init(clientName: "WEB", clientVersion: "2.20260213.00.00", clientId: 1,
              userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"),
        // Exact from Android WEB_CREATOR (1.20260213.00.00, id 62).
        .init(clientName: "WEB_CREATOR", clientVersion: "1.20260213.00.00", clientId: 62,
              userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"),
    ]

    public struct ResolvedAudio { public var videoId: String; public var audioURL: URL; public var title: String; public var lengthSec: Int? }

    public func resolveAudio(title: String, artist: String, album: String,
                             quality: AudioQuality, validate: Bool) async throws -> ResolvedAudio {
        // 1. search FILTER_SONG, 2. score vs Spotify metadata (CandidateScorer),
        // 3. player fetch at quality with validation-skipping per caller.
        // Full NewPipe-extractor parity lives in YTPlayerResolver.swift.
        let vid = try await searchFirstVideoId(query: "\(artist) - \(title)")
        return try await YTPlayerResolver.shared.audio(videoId: vid, quality: quality, validate: validate)
    }

    func searchFirstVideoId(query: String) async throws -> String {
        guard let url = URL(string: "\(Constants.innerTubeBase)/search?prettyPrint=false") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyHeaders(&req, client: Self.clients[0])
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, _) = try await Constants.retry { try await self.session.data(for: req) }
        // Minimal parse: first videoId in payload (full SearchPage model in Models/)
        let s = String(data: data, encoding: .utf8) ?? ""
        if let r = s.range(of: "\"videoId\":\""), let e = s[r.upperBound...].firstIndex(of: "\"") {
            return String(s[r.upperBound..<e])
        }
        throw URLError(.cannotParseResponse)
    }

    /// YouTube-scoped cookie allowlist. Only cookies whose domain is
    /// youtube.com (covers music.youtube.com) AND whose name belongs to the
    /// SAPISID/APISID/SSID family are sent. Never the whole shared jar —
    /// otherwise Spotify/session cookies leak to Google.
    /// NOTE: WK-cookie ingestion is still pending — the WKWebView cookie store
    /// lives outside this file (SpotifyBridge owns the WebView), so YouTube
    /// login cookies set inside the WebView are not yet ingested here; only
    /// HTTPCookieStorage.shared cookies matching the scope below are used.
    private static let ytCookieAllowlist: Set<String> = [
        "SAPISID", "__SAPISID", "APISID", "__APISID",
        "HSID", "__HSID", "SSID", "__SSID", "SID", "__SID"
    ]

    static func isYouTubeScopedCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard domain == "youtube.com" || domain.hasSuffix(".youtube.com") else { return false }
        if ytCookieAllowlist.contains(cookie.name) { return true }
        // Family suffixes: __Secure-*/__Host-* variants of SAPISID/APISID/SSID.
        let n = cookie.name
        if n.hasSuffix("SAPISID") || n.hasSuffix("APISID") { return true }
        return false
    }

    static func youTubeScopedCookies() -> [HTTPCookie] {
        return (HTTPCookieStorage.shared.cookies ?? []).filter(isYouTubeScopedCookie)
    }

    func applyHeaders(_ req: inout URLRequest, client: Client) {
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        req.setValue("\(client.clientId)", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "X-Origin")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "Referer")
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        let scoped = Self.youTubeScopedCookies()
        if !scoped.isEmpty {
            req.setValue(scoped.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
                         forHTTPHeaderField: "Cookie")
            let sapisid = scoped.first(where: { $0.name == "SAPISID" })?.value
                ?? scoped.first(where: { $0.name == "__SAPISID" })?.value
                ?? scoped.first(where: { $0.name.hasSuffix("SAPISID") })?.value
            if let sapisid = sapisid {
                let secs = Int(Date().timeIntervalSince1970)
                let raw = "\(secs) \(sapisid) https://music.youtube.com"
                let sha = Insecure.SHA1.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
                req.setValue("SAPISIDHASH \(secs)_\(sha)", forHTTPHeaderField: "Authorization")
            }
        }
    }
}

public enum AudioQuality { case high, low } // HIGH=unmetered max bitrate, LOW=metered min (+10240 opus/webm bonus)
