# MuseMobile iOS 1.1.4 (14) — smoke-1

First installable iOS rebuild for smoke testing. Swift/SwiftUI + WKWebView
wrapping `open.spotify.com`, same JS intelligence as Android (38 payloads
verbatim), native layers reimplemented.

## What's in

- WebView host: desktop UA spoof, injection order, login router, logout probe
- AndBridge: all Android method names; `nFetch` with cookie sync + 2MiB cap
- Adblock: analytics cancel, AdIdStore (≤32 LRU), proxy-mode CDN match,
  never-block music CDNs, workbox chunk untouched
- Media: lockscreen/art (≤512px), remote commands → `act*` JS, sleep timer
- Settings: all keys/defaults; AMOLED/lyrics/custom-CSS/accent theme bundle
- Offline: manifest + filename contract + ranged downloader + AVPlayer library
- Updater: GitHub `releases/latest`, per-segment compare, 12h throttle
- Build: `MuseMobileiOS.xcodeproj` + shared scheme, `sh ci/smoke.sh`

## Known issues (see SMOKE_TEST.md)

- YouTube cipher/PoToken staged — some downloads will fail
- `silent.wav` placeholder instead of `silent.mp3`
- No CarPlay entitlement; sideload only, no App Store

Tag: `v1.1.4-ios-smoke1` (CFBundleShortVersionString 1.1.4, CFBundleVersion 14)
