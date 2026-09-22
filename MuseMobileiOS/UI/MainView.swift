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
                Button("Timer") { model.startSleep(minutes: 30) }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

final class MainViewModel: ObservableObject {
    let bridge = SpotifyBridge()
    private var sleepWork: DispatchWorkItem?

    func wire() {
        bridge.onTimerDialog = { [weak self] in self?.startSleep(minutes: 30) }
        bridge.onDownloadTrack = { DownloadManager.shared.downloadTrack(json: $0) }
        bridge.onDownloadCollection = { DownloadManager.shared.downloadCollection(json: $0) }
    }

    func startSleep(minutes: Int) {
        sleepWork?.cancel()
        let w = DispatchWorkItem { WebViewBus.eval("actPlayPause(false)") }
        sleepWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(minutes * 60), execute: w)
        WebViewBus.eval("if(window.timerBtn)window.timerBtn.classList.add('spl-timer');")
    }

    func cancelSleep() {
        sleepWork?.cancel(); sleepWork = nil
        WebViewBus.eval("if(window.timerBtn)window.timerBtn.classList.remove('spl-timer');")
    }
}
