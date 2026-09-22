import SwiftUI

/// Settings UI — mirrors Android SettingsScreen/SettingsDrawer.
/// Keys + defaults per §7. LandscapeMode=false means portrait lock;
/// KeepScreenOn maps to idleTimerDisabled; SwipeStop = N/A on iOS.
struct SettingsView: View {
    @AppStorage("ConnectionMode") var connectionMode = "normal"
    @AppStorage("MaterialYou") var materialYou = false
    @AppStorage("AmoledTheme") var amoled = false
    @AppStorage("HideTopBar") var hideTopBar = false
    @AppStorage("LandscapeMode") var landscape = false
    @AppStorage("KeepScreenOn") var keepOn = false
    @AppStorage("BlockServiceWorker") var blockSW = true
    @AppStorage("LoggedIn") var loggedIn = false
    @AppStorage("APlayMode") var aplay = "disabled"
    @AppStorage("CloseNowPlay") var closeNp = true
    @AppStorage("TakeControl") var takeControl = true
    @AppStorage("HideEmptyPlayer") var hideEmpty = false
    @AppStorage("LyricsStyle") var lyrics = "fullscreen"
    @AppStorage("PlayerMode") var playerMode = "musemobile"
    @AppStorage("GuiMode") var gui = "csshack"
    @AppStorage("CustomCss") var customCss = ""
    @AppStorage("DebugOverlay") var debug = false
    @AppStorage("OfflineMode") var offline = false
    @AppStorage("AndAuto") var andAuto = true
    @AppStorage("BtAutoPause") var btPause = false
    @AppStorage("BtAutoResume") var btResume = false
    @AppStorage("HpAutoResume") var hpResume = false

    var body: some View {
        NavigationView {
            Form {
                Section("Connection") {
                    Picker("Mode", selection: $connectionMode) {
                        Text("Normal").tag("normal"); Text("MITM Proxy").tag("proxy")
                    }
                }
                Section("Player") {
                    Picker("Player", selection: $playerMode) {
                        Text("MuseMobile").tag("musemobile"); Text("Original").tag("original")
                    }
                    Picker("Autoplay", selection: $aplay) {
                        Text("Off").tag("disabled"); Text("Once").tag("onetime"); Text("Always").tag("permanent")
                    }
                    Toggle("Close Now-Playing", isOn: $closeNp)
                    Toggle("Take Control", isOn: $takeControl)
                    Toggle("Hide Empty Player", isOn: $hideEmpty)
                    Toggle("Block Service Worker", isOn: $blockSW)
                }
                Section("Appearance") {
                    Toggle("Dynamic Color", isOn: $materialYou)
                    Toggle("AMOLED", isOn: $amoled)
                    Picker("Lyrics", selection: $lyrics) {
                        Text("Fullscreen").tag("fullscreen"); Text("Compact").tag("compact")
                        Text("Karaoke").tag("karaoke"); Text("Bold").tag("bold"); Text("Default").tag("default")
                    }
                    Picker("Layout", selection: $gui) {
                        Text("CSS Hack").tag("csshack"); Text("Big Window").tag("bigwindow"); Text("None").tag("none")
                    }
                    TextField("Custom CSS", text: $customCss)
                }
                Section("System") {
                    Toggle("Allow Landscape", isOn: $landscape)
                    Toggle("Keep Screen On", isOn: $keepOn)
                    Toggle("Offline Mode", isOn: $offline)
                    Toggle("CarPlay (Android Auto)", isOn: $andAuto)
                    Toggle("BT Auto-Pause", isOn: $btPause)
                    Toggle("BT Auto-Resume", isOn: $btResume)
                    Toggle("Headphone Auto-Resume", isOn: $hpResume)
                    Toggle("Debug Overlay", isOn: $debug)
                }
                if debug { Section("Devlog") { DevLogView() } }
            }
            .navigationTitle("Settings")
        }
        .onChange(of: keepOn) { newValue in
            UIApplication.shared.isIdleTimerDisabled = newValue
        }
    }
}

struct DevLogView: View {
    @ObservedObject var store = DebugLogStore.shared
    var body: some View {
        ForEach(store.lines.suffix(100)) { l in
            Text("[\(l.tag)] \(l.msg)").font(.caption).lineLimit(3)
        }
    }
}
