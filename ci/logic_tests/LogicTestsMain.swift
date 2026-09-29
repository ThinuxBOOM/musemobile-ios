// Hardware-free logic tests: compiled with the REAL sources via
//   swiftc <sources> ci/logic_tests/LogicTestsMain.swift -o logictests && ./logictests
// Covers the pure-logic ports: AdIdStore, AdBlocker (+pipeline rule),
// JSStripper, Updater.isNewer, OfflineStore.sanitize, Constants.retry,
// AppSettings defaults. Exit 0 = all pass.
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("PASS: \(name)") }
    else { failures += 1; print("FAIL: \(name)") }
}

// ---------- AdIdStore ----------
AdIdStore.shared.clear()
check(AdIdStore.shared.addAll(["abc12345", "zz-id_99"]) == true, "adid: accepts valid ids")
check(AdIdStore.shared.matches("https://audio/x?file=abc12345&y=1") == true, "adid: matches substring")
check(AdIdStore.shared.addAll(["short", "has space!", "abc12345"]) == false, "adid: rejects short/bad/dup, no change")
check(AdIdStore.shared.addAll([String(repeating: "a", count: 129)]) == false, "adid: rejects >128 chars")
check(AdIdStore.shared.matches("https://open.spotify.com/track/x") == false, "adid: no false positive")
// LRU bound: 33 ids -> first evicted
AdIdStore.shared.clear()
AdIdStore.shared.addAll((0...32).map { "zzid\(String(format: "%04d", $0))" })
check(AdIdStore.shared.matches("xxzzid0000yy") == false, "adid: LRU evicts oldest past 32")
check(AdIdStore.shared.matches("xxzzid0032yy") == true, "adid: newest retained")
AdIdStore.shared.clear()
check(AdIdStore.shared.matches("xxzzid0032yy") == false, "adid: clear empties store")

// ---------- AdBlocker + pipeline rule ----------
// Mirrors SpotifyWebView.decidePolicyFor: analytics cancel; AdId match cancels
// unless protected music URL; proxy-mode CDN match cancels unless protected.
func pipelineAllows(_ url: String, proxy: Bool = true) -> Bool {
    if AdBlocker.isAnalytics(url) { return false }
    if AdIdStore.shared.matches(url) && !AdBlocker.isProtectedMusicURL(url) { return false }
    if proxy, AdBlocker.matchAdCdn(url) != nil, !AdBlocker.isProtectedMusicURL(url) { return false }
    return true
}
check(AdBlocker.isAnalytics("https://googleads.g.doubleclick.net/pagead/id") == true, "adblock: analytics domain")
check(AdBlocker.isAnalytics("https://open.spotify.com/") == false, "adblock: app host not analytics")
check(AdBlocker.matchAdCdn("https://ads-fa.spotify.com/ads/x") != nil, "adblock: ad cdn pattern")
check(AdBlocker.matchAdCdn("https://gew4-spclient.spotify.com/audio/abc") == nil, "adblock: music cdn never matches")
check(AdBlocker.isProtectedMusicURL("https://gew4-spclient.spotify.com/audio/abc") == true, "adblock: gew4 protected")
check(AdBlocker.isProtectedMusicURL("https://podz-content.spotify.com/audio/abc") == true, "adblock: podz protected")
check(AdBlocker.isProtectedMusicURL("https://audio-fa.scdn.co/audio/abc") == true, "adblock: audio-fa protected")
check(pipelineAllows("https://gew4-spclient.spotify.com/audio/abc") == true, "pipeline: music passes")
check(pipelineAllows("https://ads-fa.spotify.com/ads/x") == false, "pipeline: ad cdn blocked")
check(pipelineAllows("https://googleads.g.doubleclick.net/x") == false, "pipeline: analytics blocked")
AdIdStore.shared.clear()
AdIdStore.shared.addAll(["deadbeef01"])
check(pipelineAllows("https://cdn.example.com/deadbeef01.mp3") == false, "pipeline: harvested ad id blocked")
AdIdStore.shared.clear()

// ---------- JSStripper ----------
check(JSStripper.stripConsoleLogs("console.log(\"hi\")") == "void 0", "js: basic strip")
check(JSStripper.stripConsoleLogs("console.log(a.map(x => f(x)))") == "void 0", "js: nested parens")
check(JSStripper.stripConsoleLogs("console . log (x)") == "void 0", "js: whitespace tolerant")
check(JSStripper.stripConsoleLogs("console.warn(\"x\")") == "console.warn(\"x\")", "js: warn preserved")
check(JSStripper.stripConsoleLogs("window.console.log(x)") == "window.console.log(x)", "js: window.console preserved")
check(JSStripper.stripConsoleLogs("let s = \"console.log(x)\";") == "let s = \"console.log(x)\";", "js: string literal preserved")
check(JSStripper.stripConsoleLogs("let a = 1;") == "let a = 1;", "js: no-console fast path")

// ---------- Updater.isNewer (numeric per segment) ----------
check(Updater.isNewer("1.1.5", than: "1.1.4") == true, "updater: patch newer")
check(Updater.isNewer("1.1.4", than: "1.1.4") == false, "updater: equal not newer")
check(Updater.isNewer("1.1.3", than: "1.1.4") == false, "updater: older not newer")
check(Updater.isNewer("1.10.0", than: "1.9.0") == true, "updater: numeric, not lexicographic")
check(Updater.isNewer("2.0", than: "1.9.9") == true, "updater: major bump")

// ---------- OfflineStore.sanitize ----------
check(OfflineStore.sanitize("a/b?c*d") == "a_b_c_d", "sanitize: illegal chars")
check(OfflineStore.sanitize(String(repeating: "x", count: 250)).count == 200, "sanitize: 200-char cap")
check(OfflineStore.sanitize("Artist - Title [abc].m4a") == "Artist - Title [abc].m4a", "sanitize: clean passthrough")

// ---------- AppSettings defaults ----------
AppSettings.registerDefaults()
check(AppSettings.bool(.blockServiceWorker) == true, "prefs: BlockServiceWorker default true")
check(AppSettings.string(.playerMode, default: "?") == "musemobile", "prefs: PlayerMode default")
check(AppSettings.string(.aPlayMode, default: "?") == "disabled", "prefs: APlayMode default")
check(AppSettings.string(.lyricsStyle, default: "?") == "fullscreen", "prefs: LyricsStyle default")

// ---------- Constants.retry ----------
var calls = 0
let recovered = try await Constants.retry(attempts: 3) { () -> String in
    calls += 1
    if calls < 3 { throw URLError(.timedOut) }
    return "ok"
}
check(recovered == "ok" && calls == 3, "retry: transport error retried, then succeeds")
calls = 0
do {
    _ = try await Constants.retry(attempts: 3) { () -> String in
        calls += 1
        throw URLError(.cannotParseResponse)
    }
    check(false, "retry: non-retryable should throw")
} catch {
    check(calls == 1, "retry: non-retryable rethrown immediately, single attempt")
}

print(failures == 0 ? "\nALL LOGIC TESTS PASSED" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
