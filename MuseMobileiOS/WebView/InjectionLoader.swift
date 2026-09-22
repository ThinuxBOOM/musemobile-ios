import Foundation
import WebKit

/// JS injection orchestration. Mirrors `SpotifyWebViewClient` order exactly —
/// wrappers nest outside-in, so order is load-bearing.
///
/// Page-start (didCommit): flags -> spoof -> FetchOverride -> AdStateHook ->
/// Adblockify -> WorkerNeutralize? -> GaBlocker -> PowerSave -> SettingsFix -> VideoPark
/// Post-login +0.5s: PlayerCore -> TrackObserver -> ClassicBridge -> MediaUpdater ->
/// LibraryFetcher/Parser -> PlaybackControls -> AndroidAuto -> MainLoop -> AutoFeatures ->
/// AndroidTracker -> SearchOverlay -> DownloadButton/Progress -> CollectionDownload ->
/// ContextMenuDownload -> account poller -> CssHack -> ModalFix -> ErrorDialogRestyle ->
/// ToastFix -> LyricsSyncFix -> QueueAutoClose -> LibraryAutoClose -> MuseMobilePlayer?
/// + theme bundle.
public enum InjectionLoader {
    /// Ordered file names in Resources/JS (verbatim Android ports).
    public static let pageStart: [String] = [
        "FetchOverride", "AdStateHook", "Adblockify",
        "WorkerNeutralize", // gated by BlockServiceWorker
        "GaBlocker", "PowerSave", "SettingsFix", "VideoPark",
    ]
    public static let playerStack: [String] = [
        "PlayerCore", "TrackObserver", "ClassicBridge", "MediaUpdater",
        "LibraryFetcher", "LibraryParser", "PlaybackControls", "AndroidAuto",
        "MainLoop", "AutoFeatures", "AndroidTracker", "SearchOverlay",
        "DownloadButton", "DownloadProgress", "CollectionDownload",
        "ContextMenuDownload",
        // account poller is inline (see accountPollerJS)
        "CssHack", "ModalFix", "ErrorDialogRestyle", "ToastFix",
        "LyricsSyncFix", "QueueAutoClose", "LibraryAutoClose",
        "MuseMobilePlayer", // gated by PlayerMode == musemobile
    ]

    public static func jsResource(_ name: String) -> String {
        // Bundle resources are added flat (no folder reference), so no subdirectory.
        Bundle.main.path(forResource: name, ofType: "js")
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
    }

    static var stripInRelease: Bool {
#if DEBUG
        return false
#else
        return true
#endif
    }

    public static func pageStartScript(useProxy: Bool, powerSave: Bool, hideEmpty: Bool, isGoogleAuth: Bool) -> String {
        var parts: [String] = [
            "window.__musemobileUseProxy=\(useProxy ? "true" : "false");",
            "window.__splPowerSavePref=\(powerSave ? "true" : "false");",
            "window.__splHideEmpty=\(hideEmpty ? "true" : "false");",
            jsResource(isGoogleAuth ? "GoogleSpoof" : "BrowserSpoof"),
        ]
        let blockSW = AppSettings.bool(.blockServiceWorker)
        for name in pageStart {
            if name == "WorkerNeutralize" && !blockSW { continue }
            if name == "PowerSave" {
                parts.append("window.__splPowerSavePref=\(powerSave ? "true" : "false");")
            }
            parts.append(jsResource(name))
        }
        let joined = parts.joined(separator: "\n;\n")
        return stripInRelease ? JSStripper.stripConsoleLogs(joined) : joined
    }

    public static let accountPollerJS = """
    (function(){
        var recAcc=function(){
            try{
                var uw=document.querySelector('[data-testid="user-widget-link"]');
                if(uw){
                    var txt=(uw.textContent||'').split('\\n')[0].trim();
                    if(txt) AndBridge.recAccountName(txt);
                }
            }catch(e){}
        };
        setTimeout(recAcc,5000);
        setInterval(recAcc,60000);
    })();
    """

    public static func playerScript() -> String {
        let playerMode = AppSettings.string(.playerMode, default: "musemobile")
        let autoPlay = AppSettings.string(.aPlayMode, default: "disabled")
        let closeNp = AppSettings.bool(.closeNowPlay)
        let useProxy = AppSettings.string(.connectionMode, default: "normal") == "proxy"
        let takeControl = AppSettings.bool(.takeControl)
        let hideEmpty = AppSettings.bool(.hideEmptyPlayer)
        let debugOverlay = AppSettings.bool(.debugOverlay)
        var parts: [String] = [
            "window.autoPlayMode='\(autoPlay)';",
            "window.closeNpPref=\(closeNp);",
            "window.__musemobileUseProxy=\(useProxy);",
            "window.__splTakeControl=\(takeControl);",
            "window.__splHideEmpty=\(hideEmpty);",
        ]
        if debugOverlay { parts.append(ThemeJS.devLogPrelude) }
        for name in playerStack {
            if name == "MuseMobilePlayer" && playerMode != "musemobile" { continue }
            parts.append(jsResource(name))
        }
        parts.append(accountPollerJS)
        parts.append(ThemeJS.accentJS())
        parts.append(ThemeJS.amoledJS(enabled: AppSettings.bool(.amoledTheme)))
        parts.append(ThemeJS.customCssJS(AppSettings.string(.customCss)))
        parts.append(ThemeJS.lyricsStyleJS(AppSettings.string(.lyricsStyle, default: "fullscreen")))
        if playerMode == "original" {
            parts.append("(function(){var s=document.createElement('style');s.id='spl-np-show';s.textContent='aside[data-testid=\"now-playing-bar\"]{display:flex!important}';document.head.appendChild(s);})();")
        }
        let joined = parts.joined(separator: "\n;\n")
        return stripInRelease ? JSStripper.stripConsoleLogs(joined) : joined
    }
}
