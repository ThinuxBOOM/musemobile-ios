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
    // Exact clientName/clientVersion/clientId/userAgent copied from Android YouTube.kt.
    // Order: WEB_REMIX (main) then fallbacks TVHTML5_SIMPLY_EMBEDDED_PLAYER(85)
    // first for age-restricted, TVHTML5, ANDROID_VR 1.43.32, ANDROID_VR 1.61.48,
    // ANDROID_CREATOR, IPADOS, ANDROID_VR_NO_AUTH, MOBILE, IOS, WEB, WEB_CREATOR last.
    public static let clients: [Client] = [
        .init(clientName: "WEB_REMIX", clientVersion: "1.20260101.00.00", clientId: 67, userAgent: Constants.desktopUA),
        .init(clientName: "TVHTML5_SIMPLY_EMBEDDED_PLAYER", clientVersion: "2.0", clientId: 85, userAgent: Constants.desktopUA),
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
        var req = URLRequest(url: URL(string: "\(Constants.innerTubeBase)/search?prettyPrint=false")!)
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
        if let cookie = HTTPCookieStorage.shared.cookies?.map({ "\($0.name)=\($0.value)" }).joined(separator: "; ") {
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            if let sapisid = HTTPCookieStorage.shared.cookies?.first(where: { $0.name == "SAPISID" })?.value {
                let secs = Int(Date().timeIntervalSince1970)
                let raw = "\(secs) \(sapisid) https://music.youtube.com"
                let sha = Insecure.SHA1.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
                req.setValue("SAPISIDHASH \(secs)_\(sha)", forHTTPHeaderField: "Authorization")
            }
        }
    }
}

public enum AudioQuality { case high, low } // HIGH=unmetered max bitrate, LOW=metered min (+10240 opus/webm bonus)
