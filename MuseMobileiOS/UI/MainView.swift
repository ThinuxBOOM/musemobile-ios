import SwiftUI
import WebKit

/// Main screen: WKWebView + settings drawer + error + sleep timer + PiP.
/// Sleep timer: countdown -> actPlayPause(false) + timer-button highlight CSS
/// (window.pBtn/timerBtn, spl-timer). PiP: AVPictureInPictureController for
/// video; audio-only = background audio + lockscreen art.
struct MainView: View {
    @StateObject private var model = MainViewModel()
    @State private var showSettings = false
    @State private var toast: String? = nil

    var body: some View {
        ZStack {
            SpotifyWebView(bridge: model.bridge, onNavigate: { _ in })
                .ignoresSafeArea()
                .onAppear {
                    WebViewBus.eval = { [weak b = model.bridge] js in
                        DispatchQueue.main.async { b?.webView?.evaluateJavaScript(js, completionHandler: nil) }
                    }
                    ToastCenter.show = { msg in
                        DispatchQueue.main.async {
                            toast = msg.isEmpty ? nil : msg
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { toast = nil }
                    }
                    model.wire()
                }
            if let toast {
                VStack { Spacer(); Text(toast).padding(10).background(.ultraThinMaterial).cornerRadius(10).padding() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Settings") { showSettings = true }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Timer") { model.sleepInput = "30"; model.showSleepDialog = true }
            }
        }
        .alert("Sleep Timer", isPresented: $model.showSleepDialog) {
            TextField("Minutes (5–180)", text: $model.sleepInput)
                .keyboardType(.numberPad)
            Button("Start") { model.confirmSleep() }
            if model.sleepActive {
                Button("Cancel Timer", role: .destructive) { model.cancelSleep() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Stop playback after 5–180 minutes (default 30).")
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

final class MainViewModel: ObservableObject {
    let bridge = SpotifyBridge()
    private var sleepWork: DispatchWorkItem?
    @Published var showSleepDialog = false
    @Published var sleepInput = "30"
    @Published var sleepActive = false

    func wire() {
        bridge.onLoginDetected = { [weak self] in
            DispatchQueue.main.async {
                if let wv = self?.bridge.webView {
                    wv.load(URLRequest(url: Constants.spotifyHome))
                }
            }
        }
        bridge.onPlayLoaded = {
            // no-op hook: play control is wired page-side (wirePlayBtn);
            // reserved for future badge/artwork refresh.
        }
        bridge.onEnterPip = {
            // PiP stub: no WebViewBus.eval here; future AVKit work observes .requestPip.
            NotificationCenter.default.post(name: .requestPip, object: nil)
        }
        bridge.onEnterPipVideo = { w, h in
            // PiP-video stub: no WebViewBus.eval here; future AVKit work observes .requestPip.
            NotificationCenter.default.post(name: .requestPip, object: nil, userInfo: ["w": w, "h": h])
        }
        bridge.onTimerDialog = { [weak self] in
            DispatchQueue.main.async { self?.showSleepDialog = true }
        }
        bridge.onDownloadTrack = { DownloadManager.shared.downloadTrack(json: $0) }
        bridge.onDownloadCollection = { DownloadManager.shared.downloadCollection(json: $0) }
    }

    func confirmSleep() {
        let m = Int(sleepInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 30
        guard (5...180).contains(m) else { sleepInput = "30"; return }
        showSleepDialog = false
        startSleep(minutes: m)
    }

    func startSleep(minutes: Int) {
        cancelSleep()
        sleepActive = true
        let w = DispatchWorkItem { [weak self] in
            WebViewBus.eval("actPlayPause(false)")
            WebViewBus.eval("if(window.timerBtn)timerBtn.style.color='';var t=document.getElementById('spl-timer');if(t)t.classList.remove('spl-active');")
            DispatchQueue.main.async { self?.sleepActive = false }
        }
        sleepWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(minutes * 60), execute: w)
        WebViewBus.eval("if(window.timerBtn)timerBtn.style.color='var(--spl-accent,#2d6)';var t=document.getElementById('spl-timer');if(t)t.classList.add('spl-active');")
    }

    func cancelSleep() {
        sleepWork?.cancel(); sleepWork = nil
        sleepActive = false
        WebViewBus.eval("if(window.timerBtn)timerBtn.style.color='';var t=document.getElementById('spl-timer');if(t)t.classList.remove('spl-active');")
    }
}

extension Notification.Name { static let requestPip = Notification.Name("requestPip") }
