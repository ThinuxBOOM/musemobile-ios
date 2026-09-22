# MuseMobile iOS — Rebuild Scaffold (v1.1.4 / build 14)

Swift/SwiftUI + WKWebView port of [musemobile](https://github.com/ThinuxBOOM/musemobile)
(Android: Kotlin, WebView wrapping `https://open.spotify.com/`).

> ~60% of product intelligence lives in JS — `Resources/JS/*.js` are **verbatim
> ports** of Android `webview/injections/*.kt` (38 payloads, extracted by script).
> Native layers below reimplement the contracts in `Ref` brief §§1–8.

## Layout

```
MuseMobileiOS/
  MuseMobileApp.swift            App entry (dark-only, bg audio)
  Info.plist                     bundle id com.musemobile.ios, 1.1.4 (14), audio bg mode
  Core/AppSettings.swift         all UserDefaults keys + defaults (§7)
  Core/Constants.swift           desktop UA, client hints, timeouts, retry policy
  Core/JSStripper.swift          JsUtils.stripConsoleLogs port (release strips)
  Core/Support.swift             ToastCenter + DebugLogStore
  WebView/SpotifyWebView.swift   WKWebView host, page-start/finish order, adblock decidePolicy
  WebView/InjectionLoader.swift  load-bearing injection order (§2)
  WebView/AdBlocker.swift        analytics/ad-audio/ad-CDN lists + never-block rule (§3)
  WebView/AdIdStore.swift        ≤32 LRU IDs, lock-free reads, clear on navigate (§3)
  WebView/ThemeJS.swift          Accent/Amoled/CustomCss/Lyrics builders + DevLogPrelude
  Bridge/SpotifyBridge.swift     AndBridge handler + nFetch (cookie sync, 10s, 2MiB cap)
  Resources/JS/*.js              38 verbatim payloads + __BridgeShim.js
  Media/NowPlayingManager.swift  MPNowPlayingInfoCenter + MPRemoteCommandCenter -> act* JS
  Media/CarPlayManager.swift     MPPlayableContentManager tabs via fetchMediaItems/search
  Offline/OfflineStore.swift     manifest + filename regex
  Offline/DownloadManager.swift  InnerTube HIGH resolve + 8MiB ranged chunks + splDownloadProgress
  YouTube/InnerTube.swift        clients (WEB_REMIX/67 main + fallbacks), SAPISIDHASH
  YouTube/YTPlayerResolver.swift format pick, cipher/PoToken hooks
  Proxy/LocalProxyManager.swift  Network.framework stub (per-view proxy N/A — use mngFetch)
  Updater/Updater.swift          GitHub releases/latest, per-segment compare, 12h throttle
  UI/RootView.swift              splash/router + cert gate + error mapping
  UI/MainView.swift              webview + timer (actPlayPause) + PiP hooks
  UI/SettingsView.swift          all settings
  UI/OfflineView.swift           AVPlayer library
```

## Bring-up (Xcode, macOS)

1. Open `MuseMobileiOS.xcodeproj` (shared scheme `MuseMobileiOS` included) or
   run `sh ci/smoke.sh` for an unsigned `CODE_SIGNING_ALLOWED=NO` build check.
2. Set your Team for device install (bundle `com.musemobile.ios`).
3. Build & run on device (Spotify web player needs real network + cookies).

## Ship to iPhone (sideload — no App Store)

Tapping an IPA in Safari installs nothing. iOS needs a **signed** app
installed via Xcode/AltStore. Fastest smoke path is a cable install
(§Bring-up). For a GitHub release others can install:

1. Push + tag: `git add -A && git commit -m "ios smoke-1" && git push`,
   `git tag v1.1.4-ios-smoke1 && git push --tags`
2. On macOS: put your Team ID in `ci/exportOptions-development.plist`
   (`YOUR_TEAM_ID`), then `TEAM_ID=... sh ci/archive.sh development`
   → `build/export/MuseMobileiOS.ipa`
3. `python3 ci/make_altstore.py --ipa build/export/MuseMobileiOS.ipa --user <you> --repo <ios-repo> --tag v1.1.4-ios-smoke1`
   → `altstore/apps.json` (size + date auto-filled); commit + push
4. GitHub → Releases → New (tag `v1.1.4-ios-smoke1`) → attach the `.ipa`
   (+ `RELEASE_NOTES_1.1.4-ios-smoke1.md` body)
5. iPhone: install AltStore (AltServer on PC, same Wi-Fi, Apple ID), add source
   `https://raw.githubusercontent.com/<you>/<ios-repo>/main/altstore/apps.json`,
   install MuseMobile. Free IDs: 3-app limit, 7-day refresh via AltServer.
   Enable Developer Mode first (Settings → Privacy & Security, iOS 16+).

## Contracts preserved

- Entry URLs: logged-in `open.spotify.com/`, logged-out `accounts.spotify.com/login`;
  `LoggedIn` set by `AndBridge.loginDetected()`, cleared on `LogoutCheck=="out"`.
- Spoof: UA Chrome/150 Win64 + sec-ch-ua* + sec-gpc:1, BrowserSpoof/GoogleSpoof,
  1920×1080, WebGL ANGLE/NVIDIA. Multi-window only Spotify/OAuth hosts.
- `nFetch(url,{method,headers,body})→{status,body,headers}`: desktop headers,
  Origin/Referer for Spotify hosts, cookie sync both ways, 10s, 2MiB cap.
- Adblock: analytics→cancel; AdIdStore match→cancel + silent.mp3; proxy mode
  matchAdCdn→cancel. Never block gew4-spclient/audio-fa/podz-content/scdn audio.
  Workbox chunk never blocked.
- Downloads progress: `window.__splDlBatch;window.splDownloadProgress(pct,'label')`.
- Theme element IDs: `musemobile-amoled-theme`, `musemobile-custom-css`,
  `musemobile-lyrics-style`, `--spl-accent*` vars.

## iOS warnings (§8)

- **Distribution is the hard problem**: App Store will reject a Spotify adblocker.
  Plan AltStore / TestFlight / dev-signing from day one.
- WKWebView ignores per-view proxies — API traffic goes via native URLSession
  (`mngFetch`); proxy mode only affects native session + resource loader.
- `silent.mp3`: add a 1s silent MPEG (e.g. `ffmpeg -f lavfi -i anullsrc=r=44100:cl=mono -t 1 -q:a 9 silent.mp3`)
  at `Resources/silent.mp3` and return it from the resource loader for cancelled ad audio.
- WebSocket dealer traffic bypasses fetch shims — AdStateHook WS wrap is load-bearing.
- Firebase skipped (Android ships collection-disabled; 3 playback-failure paths → os_log).

## Next steps

- [ ] Full `LyricsTheme.kt` (404 lines) CSS → `LyricsCSS.swift` (scaffold has seam-fix + marker)
- [ ] `AVAssetResourceLoaderDelegate` redirect for `<audio>` ad URLs → bundled silent.mp3
- [ ] Cipher `base.js` 6h cache + locked-down WKWebView executor; PoToken minter (12s, single-flight)
- [ ] `MPPlayableContentManager` data source wiring + CarPlay entitlement
- [ ] NETransparentProxy leaf-cert issuance + `MuseMobile_CA.pem` export/share
- [ ] Release-body markdown renderer (headings/lists/code/quotes/links) in updater sheet
