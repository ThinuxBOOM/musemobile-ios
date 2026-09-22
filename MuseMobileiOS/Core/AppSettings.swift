import Foundation

/// UserDefaults keys — mirrors Android `musemobile_prefs`.
/// All defaults match §7 of the rebuild brief.
public enum AppSettings {
    public static let suite = UserDefaults.standard

    public enum Key: String, CaseIterable {
        case connectionMode = "ConnectionMode"       // normal|proxy
        case serviceOn = "ServiceOn"
        case materialYou = "MaterialYou"
        case amoledTheme = "AmoledTheme"
        case hideTopBar = "HideTopBar"
        case landscapeMode = "LandscapeMode"         // false = portrait lock
        case keepScreenOn = "KeepScreenOn"           // -> idleTimerDisabled
        case paletteSeed = "PaletteSeed"             // nil = default (#RRGGBB or absent)
        case blockServiceWorker = "BlockServiceWorker"
        case powerSave = "PowerSave"                 // no UI, keep supported
        case loggedIn = "LoggedIn"
        case currentAccountName = "CurrentAccountName"
        case aPlayMode = "APlayMode"                 // disabled|onetime|permanent
        case closeNowPlay = "CloseNowPlay"
        case takeControl = "TakeControl"
        case hideEmptyPlayer = "HideEmptyPlayer"
        case lyricsStyle = "LyricsStyle"             // fullscreen|compact|karaoke|bold|default
        case playerMode = "PlayerMode"               // musemobile|original
        case guiMode = "GuiMode"                     // csshack|bigwindow|none
        case customCss = "CustomCss"
        case debugOverlay = "DebugOverlay"
        case offlineMode = "OfflineMode"
        case andAuto = "AndAuto"                     // CarPlay enabled
        case btAutoPause = "BtAutoPause"
        case btAutoResume = "BtAutoResume"
        case hpAutoResume = "HpAutoResume"
        case lastUpdateCheck = "LastUpdateCheck"     // ms epoch
    }

    public static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.connectionMode.rawValue: "normal",
            Key.serviceOn.rawValue: true,
            Key.materialYou.rawValue: false,
            Key.amoledTheme.rawValue: false,
            Key.hideTopBar.rawValue: false,
            Key.landscapeMode.rawValue: false,
            Key.keepScreenOn.rawValue: false,
            Key.blockServiceWorker.rawValue: true,
            Key.powerSave.rawValue: false,
            Key.loggedIn.rawValue: false,
            Key.aPlayMode.rawValue: "disabled",
            Key.closeNowPlay.rawValue: true,
            Key.takeControl.rawValue: true,
            Key.hideEmptyPlayer.rawValue: false,
            Key.lyricsStyle.rawValue: "fullscreen",
            Key.playerMode.rawValue: "musemobile",
            Key.guiMode.rawValue: "csshack",
            Key.customCss.rawValue: "",
            Key.debugOverlay.rawValue: false,
            Key.offlineMode.rawValue: false,
            Key.andAuto.rawValue: true,
            Key.btAutoPause.rawValue: false,
            Key.btAutoResume.rawValue: false,
            Key.hpAutoResume.rawValue: false,
            Key.lastUpdateCheck.rawValue: 0,
        ])
    }

    public static subscript(key: Key) -> Any? {
        get { UserDefaults.standard.object(forKey: key.rawValue) }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: key.rawValue) }
            else { UserDefaults.standard.removeObject(forKey: key.rawValue) }
        }
    }

    public static func bool(_ key: Key) -> Bool { UserDefaults.standard.bool(forKey: key.rawValue) }
    public static func string(_ key: Key, default v: String = "") -> String {
        UserDefaults.standard.string(forKey: key.rawValue) ?? v
    }
}
