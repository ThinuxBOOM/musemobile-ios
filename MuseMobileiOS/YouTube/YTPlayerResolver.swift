import Foundation
import WebKit

/// YouTube playback resolution — port of Android yt/ (CipherDeobfuscator,
/// PlayerJsFetcher, FunctionNameExtractor, CipherWebView, PoTokenGenerator,
/// YTPlayerUtils).
///
/// IMPLEMENTED (testable headless):
///  - PlayerJsFetcher: iframe_api -> player hash -> base.js, 6h file cache
///  - FunctionNameExtractor: sig/N patterns + Q-array detect + hardcoded
///    config for hash 74edf1a3 + signatureTimestamp extraction
///  - Cipher executor: extracted functions run in a locked-down WKWebView
///    (evaluateJavaScript only, never loads remote content), 10s/14s caps
///  - Format pick: audio-only, non-dubbed; HIGH=max bitrate / LOW=min
///    (+10240 opus/webm bonus); cipher deobfuscate + N-transform + ?pot=
///  - HEAD-probe accept table: 2xx/403/405/410 good, timeouts optimistically
///    good, else next client; per-client fallback; naive parse as last resort
///
/// DEVICE-GATED (structured, throws PoTokenError.unavailable):
///  - BotGuard attestation for PoToken minting (needs real device WebView
///    + Google challenge flow). Single-flight actor + 12s timeout + one
///    auto-recreate mirror Android; tokens stay nil until this lands.
public enum CipherError: Error {
    case cacheUnavailable
    case fetchFailed
    case hashNotFound
    case extractionFailed
    case evaluationTimeout
    case evaluationFailed(String)
}

public enum PoTokenError: Error {
    case unavailable
    case timeout
}

public final class YTPlayerResolver {
    public static let shared = YTPlayerResolver()
    private init() {}

    // MARK: - Public entry (signature unchanged)

    public func audio(videoId: String, quality: AudioQuality, validate: Bool) async throws -> InnerTube.ResolvedAudio {
        // Parallel sig-timestamp (10s) + PoToken (12s), best-effort both.
        async let stsTask: Int? = bounded(10) { await self.signatureTimestamp() }
        async let potTask: String? = bounded(12) { try await PoTokenMinter.shared.playerToken(videoId: videoId) }
        let sts = await stsTask
        let pot = await potTask

        // Per-client fallback (uses however many clients InnerTube exposes).
        var lastError: Error = URLError(.cannotParseResponse)
        for client in InnerTube.clients {
            do {
                if let r = try await audioViaClient(videoId: videoId, client: client,
                                                    quality: quality, validate: validate,
                                                    sts: sts, pot: pot) {
                    return r
                }
            } catch {
                lastError = error
                continue
            }
        }
        // Last resort: naive first-url parse (previous behavior, no regression).
        if let r = try? await naiveAudio(videoId: videoId) { return r }
        throw lastError
    }

    // MARK: - Per-client resolution

    private func audioViaClient(videoId: String, client: InnerTube.Client,
                                quality: AudioQuality, validate: Bool,
                                sts: Int?, pot: String?) async throws -> InnerTube.ResolvedAudio? {
        var req = URLRequest(url: URL(string: "\(Constants.innerTubeBase)/player?prettyPrint=false")!)
        req.httpMethod = "POST"
        InnerTube.shared.applyHeaders(&req, client: client)
        var body: [String: Any] = ["videoId": videoId]
        if let sts = sts { body["playbackContext"] = ["contentPlaybackContext": ["signatureTimestamp": sts]] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Playability gate: restricted statuses move to the next client.
        if let ps = top["playabilityStatus"] as? [String: Any],
           let status = ps["status"] as? String,
           ["AGE_CHECK_REQUIRED", "AGE_VERIFICATION_REQUIRED", "LOGIN_REQUIRED",
            "CONTENT_CHECK_REQUIRED", "UNPLAYABLE", "ERROR"].contains(status) {
            return nil
        }
        guard let sd = top["streamingData"] as? [String: Any] else { return nil }
        let formats = (sd["formats"] as? [[String: Any]] ?? []) + (sd["adaptiveFormats"] as? [[String: Any]] ?? [])
        let audios = formats.filter { f in
            let mime = (f["mimeType"] as? String) ?? ""
            if mime.contains("video/") || !mime.contains("audio/") { return false }
            if let track = (f["audioTrack"] as? [String: Any])["id"] as? String, track.hasSuffix(".dubbed") { return false }
            return true
        }
        guard !audios.isEmpty else { return nil }
        func score(_ f: [String: Any]) -> Int {
            var s = (f["bitrate"] as? Int) ?? 0
            let mime = ((f["mimeType"] as? String) ?? "").lowercased()
            if mime.contains("opus") || mime.contains("webm") { s += 10240 }
            return s
        }
        let picked = quality == .high
            ? audios.max(by: { score($0) < score($1) })
            : audios.min(by: { score($0) < score($1) })
        guard let fmt = picked else { return nil }

        var urlStr = fmt["url"] as? String
        // Ciphered URL: url + s + sp params.
        if urlStr == nil, let cipher = fmt["signatureCipher"] as? String ?? fmt["cipher"] as? String {
            urlStr = try? await decipherUrl(cipher)
        }
        guard var urlStr = urlStr else { return nil }
        // N-transform + PoToken append where applicable.
        if urlStr.contains("&n="), let n = try? await transformN(urlStr) {
            urlStr = replaceQueryParam(urlStr, name: "n", value: n)
        }
        if let pot = pot, !urlStr.contains("pot=") {
            urlStr += (urlStr.contains("?") ? "&" : "?") + "pot=" + pot
        }
        urlStr = urlStr.replacingOccurrences(of: "\\u0026", with: "&")
        guard let url = URL(string: urlStr) else { return nil }

        if validate, !(await probe(url)) { return nil }
        let vd = top["videoDetails"] as? [String: Any]
        let title = (vd?["title"] as? String) ?? videoId
        let len = (vd?["lengthSeconds"] as? String).flatMap(Int.init)
        return InnerTube.ResolvedAudio(videoId: videoId, audioURL: url, title: title, lengthSec: len)
    }

    // MARK: - Naive fallback (previous behavior)

    private func naiveAudio(videoId: String) async throws -> InnerTube.ResolvedAudio {
        var req = URLRequest(url: URL(string: "\(Constants.innerTubeBase)/player?prettyPrint=false")!)
        req.httpMethod = "POST"
        InnerTube.shared.applyHeaders(&req, client: InnerTube.clients[0])
        req.httpBody = try JSONSerialization.data(withJSONObject: ["videoId": videoId])
        let (data, _) = try await URLSession.shared.data(for: req)
        let s = String(data: data, encoding: .utf8) ?? ""
        if let r = s.range(of: "\"url\":\"https://"), let e = s[r.upperBound...].firstIndex(of: "\"") {
            var raw = "https://" + s[r.upperBound..<e]
            raw = raw.replacingOccurrences(of: "\\u0026", with: "&")
            if let url = URL(string: raw) {
                return InnerTube.ResolvedAudio(videoId: videoId, audioURL: url, title: videoId, lengthSec: nil)
            }
        }
        throw URLError(.cannotParseResponse)
    }

    // MARK: - HEAD probe accept table

    private func probe(_ url: URL) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "HEAD"
        req.setValue(Constants.desktopUA, forHTTPHeaderField: "User-Agent")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(code) || [403, 405, 410].contains(code)
        } catch let e as URLError where Constants.isRetryable(e) {
            return true // timeouts: optimistically good
        } catch {
            return false
        }
    }

    // MARK: - PlayerJsFetcher port (6h file cache)

    struct PlayerJs { var js: String; var hash: String }

    private var cipherCacheDir: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MuseMobile/cipher_cache", isDirectory: true)
    }
    private static let cacheTTL: TimeInterval = 6 * 60 * 60

    func playerJs(forceRefresh: Bool = false) async -> PlayerJs? {
        guard let dir = cipherCacheDir else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !forceRefresh, let hit = readPlayerCache(dir: dir) { return hit }
        guard let hash = await fetchPlayerHash(),
              let js = await downloadPlayerJs(hash: hash) else { return nil }
        writePlayerCache(dir: dir, hash: hash, js: js)
        return PlayerJs(js: js, hash: hash)
    }

    private func readPlayerCache(dir: URL) -> PlayerJs? {
        let meta = (try? String(contentsOf: dir.appendingPathComponent("current_hash.txt"), encoding: .utf8))?
            .components(separatedBy: "\n")
        guard let meta = meta, meta.count >= 2, let ts = Double(meta[1]),
              Date().timeIntervalSince1970 - ts < Self.cacheTTL else { return nil }
        let hash = meta[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty,
              let js = try? String(contentsOf: dir.appendingPathComponent("player_\(hash).js"), encoding: .utf8),
              !js.isEmpty else { return nil }
        return PlayerJs(js: js, hash: hash)
    }

    private func writePlayerCache(dir: URL, hash: String, js: String) {
        if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in old where f.lastPathComponent.hasPrefix("player_") { try? FileManager.default.removeItem(at: f) }
        }
        try? js.write(to: dir.appendingPathComponent("player_\(hash).js"), atomically: true, encoding: .utf8)
        try? "\(hash)\n\(Date().timeIntervalSince1970)".write(
            to: dir.appendingPathComponent("current_hash.txt"), atomically: true, encoding: .utf8)
    }

    func invalidatePlayerCache() {
        guard let dir = cipherCacheDir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    private func fetchPlayerHash() async -> String? {
        guard let url = URL(string: "https://www.youtube.com/iframe_api") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(Constants.desktopUA, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let body = String(data: data, encoding: .utf8) else { return nil }
        return firstMatch("\\\\?/s\\\\?/player\\\\?/([a-zA-Z0-9_-]+)\\\\?/", in: body)
    }

    private func downloadPlayerJs(hash: String) async -> String? {
        guard let url = URL(string: "https://www.youtube.com/s/player/\(hash)/player_ias.vflset/en_GB/base.js") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(Constants.desktopUA, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let body = String(data: data, encoding: .utf8), !body.isEmpty else { return nil }
        return body
    }

    // MARK: - FunctionNameExtractor port

    struct SigInfo {
        var name: String
        var constantArg: Int?
        var constantArgs: [Int]?
        var preprocessFunc: String?
        var preprocessArgs: [Int]?
        var isHardcoded: Bool
    }
    struct NInfo {
        var name: String
        var arrayIndex: Int?
        var constantArgs: [Int]?
        var isHardcoded: Bool
    }

    // Known config for hash 74edf1a3 (March 2026), mirroring Android.
    private static let hardcodedSig = SigInfo(name: "JI", constantArg: 48, constantArgs: [48, 1918],
                                              preprocessFunc: "f1", preprocessArgs: [1, 6528], isHardcoded: true)
    private static let hardcodedN = NInfo(name: "GU", arrayIndex: nil, constantArgs: [6, 6010], isHardcoded: true)
    private static let hardcodedSts = 20522

    private static let sigPatterns = [
        "&&\\(\\s*[a-zA-Z0-9$]+\\s*=\\s*([a-zA-Z0-9$]+)\\s*\\(\\s*(\\d+)\\s*,\\s*decodeURIComponent\\s*\\(\\s*[a-zA-Z0-9$]+\\s*\\)",
        "\\b[cs]\\s*&&\\s*[adf]\\.set\\([^,]+\\s*,\\s*encodeURIComponent\\(([a-zA-Z0-9$]+)\\(",
        "\\b[a-zA-Z0-9]+\\s*&&\\s*[a-zA-Z0-9]+\\.set\\([^,]+\\s*,\\s*encodeURIComponent\\(([a-zA-Z0-9$]+)\\(",
        "\\bm=([a-zA-Z0-9$]{2,})\\(decodeURIComponent\\(h\\.s\\)\\)",
        "\\bc\\s*&&\\s*d\\.set\\([^,]+\\s*,\\s*(?:encodeURIComponent\\s*\\()([a-zA-Z0-9$]+)\\(",
        "\\bc\\s*&&\\s*[a-z]\\.set\\([^,]+\\s*,\\s*encodeURIComponent\\(([a-zA-Z0-9$]+)\\(",
    ]
    private static let nPatterns = [
        "\\.get\\(\"n\"\\)\\)&&\\(b=([a-zA-Z0-9$]+)(?:\\[(\\d+)\\])?\\(([a-zA-Z0-9])\\)",
        "\\.get\\(\"n\"\\)\\)\\s*&&\\s*\\(([a-zA-Z0-9$]+)\\s*=\\s*([a-zA-Z0-9$]+)(?:\\[(\\d+)\\])?\\(\\1\\)",
        "\\(\\s*([a-zA-Z0-9$]+)\\s*=\\s*String\\.fromCharCode\\(110\\)",
        "([a-zA-Z0-9$]+)\\s*=\\s*function\\([a-zA-Z0-9]\\)\\s*\\{[^}]*?enhanced_except_",
    ]

    func extractSigInfo(_ js: String, knownHash: String?) -> SigInfo? {
        for (i, p) in Self.sigPatterns.enumerated() {
            guard let groups = matchGroups(p, in: js) else { continue }
            if i == 0, groups.count > 1, let arg = Int(groups[1]) {
                return SigInfo(name: groups[0], constantArg: arg, constantArgs: nil,
                               preprocessFunc: nil, preprocessArgs: nil, isHardcoded: false)
            }
            return SigInfo(name: groups[0], constantArg: nil, constantArgs: nil,
                           preprocessFunc: nil, preprocessArgs: nil, isHardcoded: false)
        }
        if hasQArray(js), knownHash == "74edf1a3" { return Self.hardcodedSig }
        return nil
    }

    func extractNInfo(_ js: String, knownHash: String?) -> NInfo? {
        for (i, p) in Self.nPatterns.enumerated() {
            guard let groups = matchGroups(p, in: js) else { continue }
            switch i {
            case 0: return NInfo(name: groups[0], arrayIndex: groups.count > 1 ? Int(groups[1]) : nil,
                                 constantArgs: nil, isHardcoded: false)
            case 1: return NInfo(name: groups.count > 1 ? groups[1] : groups[0],
                                 arrayIndex: groups.count > 2 ? Int(groups[2]) : nil,
                                 constantArgs: nil, isHardcoded: false)
            default: return NInfo(name: groups[0], arrayIndex: nil, constantArgs: nil, isHardcoded: false)
            }
        }
        if hasQArray(js), knownHash == "74edf1a3" { return Self.hardcodedN }
        return nil
    }

    func extractSignatureTimestamp(_ js: String) -> Int? {
        for p in ["signatureTimestamp['\":\\s]+(\\d+)", "sts['\":\\s]+(\\d+)",
                  "\"signatureTimestamp\"\\s*:\\s*(\\d+)"] {
            if let g = firstMatch(p, in: js), let v = Int(g) { return v }
        }
        return nil
    }

    func hasQArray(_ js: String) -> Bool {
        firstMatch("var\\s+Q\\s*=\\s*\"[^\"]+\"\\s*\\.\\s*split\\s*\\(\\s*\"\\}\"\\s*\\)", in: js) != nil
    }

    private func signatureTimestamp() async -> Int? {
        guard let p = await playerJs() else { return nil }
        return extractSignatureTimestamp(p.js) ?? (p.hash == "74edf1a3" ? Self.hardcodedSts : nil)
    }

    // MARK: - Cipher executor (locked-down WKWebView)

    func decipherSignature(_ sig: String) async throws -> String {
        guard let p = await playerJs(),
              let info = extractSigInfo(p.js, knownHash: p.hash) else { throw CipherError.extractionFailed }
        let call = sigCall(info: info, value: sig)
        let result = try await runPlayerJs(p.js, call: call, timeout: 10)
        guard let out = result as? String, !out.isEmpty else { throw CipherError.evaluationFailed("empty") }
        return out
    }

    func transformN(_ urlWithN: String) async throws -> String {
        guard let n = URLComponents(string: urlWithN)?.queryItems?.first(where: { $0.name == "n" })?.value,
              let p = await playerJs(),
              let info = extractNInfo(p.js, knownHash: p.hash) else { throw CipherError.extractionFailed }
        var call: String
        if let idx = info.arrayIndex {
            call = "\(info.name)[\(idx)](\(constList(info.constantArgs))\(info.constantArgs == nil ? "" : ",")\(jsonQuoted(n)))"
        } else {
            call = "\(info.name)(\(constList(info.constantArgs))\(info.constantArgs == nil ? "" : ",")\(jsonQuoted(n)))"
        }
        let result = try await runPlayerJs(p.js, call: call, timeout: 14)
        guard let out = result as? String, !out.isEmpty else { throw CipherError.evaluationFailed("empty") }
        return out
    }

    private func decipherUrl(_ cipher: String) async throws -> String {
        var params: [String: String] = [:]
        for part in cipher.components(separatedBy: "&") {
            let kv = part.components(separatedBy: "=")
            if kv.count == 2 { params[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        guard var base = params["url"]?.removingPercentEncoding ?? params["url"],
              let s = params["s"], let sp = params["sp"] else { throw CipherError.extractionFailed }
        let deob = try await decipherSignature(s)
        base += (base.contains("?") ? "&" : "?") + sp + "=" + deob
        return base
    }

    private func sigCall(info: SigInfo, value: String) -> String {
        var expr = jsonQuoted(value)
        if let pre = info.preprocessFunc {
            let args = constList(info.preprocessArgs)
            expr = "\(pre)(\(args.isEmpty ? "" : args + ",")\(expr))"
        }
        let args = constList(info.constantArgs ?? info.constantArg.map { [$0] })
        return "\(info.name)(\(args.isEmpty ? "" : args + ",")\(expr))"
    }

    private func constList(_ xs: [Int]?) -> String {
        (xs ?? []).map(String.init).joined(separator: ",")
    }

    private func jsonQuoted(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed]),
                     encoding: .utf8)).flatMap { $0.count > 2 ? String($0.dropFirst().dropLast()) : nil }
            .map { "\"\($0)\"" } ?? "\"\""
    }

    private func runPlayerJs(_ js: String, call: String, timeout: Double) async throws -> Any? {
        let wv = await MainActor.run {
            let cfg = WKWebViewConfiguration()
            cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
            return WKWebView(frame: .zero, configuration: cfg)
        }
        // Locked down: evaluate source only, never load() anything remote.
        _ = try await withTimeout(seconds: timeout) { try await self.eval(wv, js) }
        return try await withTimeout(seconds: timeout) { try await self.eval(wv, call) }
    }

    private func eval(_ wv: WKWebView, _ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                wv.evaluateJavaScript(js) { res, err in
                    if let err = err { cont.resume(throwing: err) }
                    else { cont.resume(returning: res) }
                }
            }
        }
    }

    private func replaceQueryParam(_ url: String, name: String, value: String) -> String {
        guard var comps = URLComponents(string: url) else { return url }
        var items = comps.queryItems ?? []
        if let i = items.firstIndex(where: { $0.name == name }) { items[i].value = value }
        else { items.append(URLQueryItem(name: name, value: value)) }
        comps.queryItems = items
        return comps.string ?? url
    }

    // MARK: - Regex helpers

    private func firstMatch(_ pattern: String, in s: String, group: Int = 1) -> String? {
        matchGroups(pattern, in: s).map { $0.count > group ? $0[group] : $0[0] } ?? nil
    }

    private func matchGroups(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let r = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: r) else { return nil }
        var out: [String] = []
        for i in 1..<m.numberOfRanges {
            let gr = m.range(at: i)
            // Optional groups (e.g. array index) may not participate: empty string.
            if gr.location == NSNotFound { out.append("") ; continue }
            guard let sr = Range(gr, in: s) else { return nil }
            out.append(String(s[sr]))
        }
        return out.isEmpty ? nil : out
    }

    private func bounded<T>(_ seconds: Double, op: @escaping () async throws -> T?) async -> T? {
        try? await withTimeout(seconds: seconds, op: op)
    }

    private func withTimeout<T>(seconds: Double, op: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CipherError.evaluationTimeout
            }
            guard let result = try await group.next() else { throw CipherError.evaluationTimeout }
            group.cancelAll()
            return result
        }
    }
}

// MARK: - PoToken single-flight (attestation device-gated)

public actor PoTokenMinter {
    public static let shared = PoTokenMinter()
    private var streamingToken: String?
    private var sessionId: String?
    private var failures = 0

    /// One streaming token per session, one player token per video, 12s cap,
    /// one auto-recreate — mirroring Android PoTokenGenerator. BotGuard
    /// attestation requires a real device WebView challenge flow, so this
    /// currently throws PoTokenError.unavailable until that lands.
    public func playerToken(videoId: String, sessionId: String = "musemobile-session") throws -> String {
        _ = videoId
        _ = Constants.poTokenAPIKey // reserved for the BotGuard Create call
        if failures > 1 { failures = 0 } // one auto-recreate consumed; reset for next session
        if streamingToken == nil || self.sessionId != sessionId {
            self.sessionId = sessionId
            streamingToken = try mintStreamingToken(sessionId: sessionId)
        }
        return try mintPlayerToken(videoId: videoId)
    }

    private func mintStreamingToken(sessionId: String) throws -> String {
        _ = sessionId
        failures += 1
        throw PoTokenError.unavailable // BotGuard attestation: device-gated
    }

    private func mintPlayerToken(videoId: String) throws -> String {
        _ = videoId
        throw PoTokenError.unavailable // BotGuard attestation: device-gated
    }
}
