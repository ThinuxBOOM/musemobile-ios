# Smoke Test — MuseMobile iOS 1.1.4 (build 14), smoke-1

Scope: unsigned Debug build on a real device via Xcode (Simulator lacks
Spotify DRM/playback). ~30 min. Report pass/fail per line.

## 0. Build & install (macOS + Xcode 15+)

- [ ] `sh ci/smoke.sh` → `SMOKE BUILD OK`
- [ ] Open `MuseMobileiOS.xcodeproj`, set Team, run on device (iOS 16+)
- [ ] App launches → Splash → main (logged-out → `accounts.spotify.com/login`)

## 1. Auth & player boot

- [ ] Log in with Spotify account → redirected to `open.spotify.com/`
- [ ] `LoggedIn` persists (kill + relaunch → straight to player, no login)
- [ ] Custom bottom bar appears (`musemobilePlayerControls`); no vanilla bar
- [ ] Settings → PlayerMode=original → vanilla bar returns; back → custom bar

## 2. Playback & media integration

- [ ] Play a track: audio out, custom bar shows title/artist/cover
- [ ] Lock screen shows MuseMobile metadata + ≤512px art; play/pause/next/prev work
- [ ] Control Center seek works (`actSeek`); like/shuffle/repeat toggle
- [ ] Background audio continues with screen locked (5 min)
- [ ] Sleep timer (Timer button, 30 min default): fires → pause + highlight clears

## 3. Adblock spot-check (do NOT log in with primary account expectations)

- [ ] Play a known ad-heavy free-tier session 15 min: no audible ads
- [ ] No silent 30s holes stuck (skip watchdog advances)
- [ ] Music never interrupted; `gew4-spclient`/`podz-content` URLs untouched
- [ ] DebugOverlay ON → Settings > Devlog shows `js` lines, no error spam

## 4. Settings & theme

- [ ] AMOLED toggle → pure-black surfaces, no reload needed
- [ ] Lyrics style fullscreen/compact/karaoke/bold/default all apply; default removes element
- [ ] Custom CSS applies; clearing removes `musemobile-custom-css`
- [ ] Keep Screen On toggles idle timer; portrait lock holds (Landscape off)
- [ ] BlockServiceWorker off → reload; on → re-neutralize, player still boots

## 5. Offline (expected: search/resolve may fail — PoToken/cipher staged)

- [ ] Download button on a track → progress callback moves (`splDownloadProgress`)
- [ ] If resolve succeeds: file lands `MuseMobile/<Artist> - <Title> [id].m4a`, manifest row written
- [ ] OfflineMode → OfflineView lists tracks; AVPlayer plays one
- [ ] skipDownload/cancelDownload from page stop the job

## 6. Updater & misc

- [ ] cold start does NOT prompt update when on latest (12h throttle)
- [ ] Proxy mode → cert gate appears; "Switch to Normal" escapes to main
- [ ] No crash on airplane-toggle → error screen + Retry reloads

## Known smoke-1 limitations

- YouTube cipher/PoToken are staged stubs (`YTPlayerResolver` naive parse) —
  downloads may fail on signature-walled tracks; log videoId + move on.
- `silent.wav` ships instead of `silent.mp3` (no ffmpeg on build host);
  ad-audio is cancelled + page-side skipped, so no asset is played yet.
  Replace: `ffmpeg -f lavfi -i anullsrc=r=44100:cl=mono -t 1 -q:a 9 silent.mp3`.
- No CarPlay entitlement in this build; CarPlayManager is backend-only.
- No App Store distribution (adblocker → rejection); sideload/AltStore only.
