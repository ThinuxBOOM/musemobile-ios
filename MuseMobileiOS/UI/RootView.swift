import SwiftUI

/// Splash/router: offline check -> proxy/cert gate -> main.
/// Mirrors Android SplashActivity + OfflineActivity routing + error mapping
/// (Offline/Timeout/Can't-reach/SSL w/ proxy hint/Server-error/Generic + Retry).
enum Route { case splash, certGate, main, offline }

struct RootView: View {
    @State private var route: Route = .splash
    @State private var error: String? = nil

    var body: some View {
        Group {
            switch route {
            case .splash: SplashView(onDone: decide)
            case .certGate: CertGateView(onDone: { route = .main }, onNormal: { route = .main })
            case .main: MainView()
            case .offline: OfflineView()
            }
        }
        .preferredColorScheme(.dark)
        .task { await checkUpdate() }
    }

    private func decide(_ err: String?) {
        error = err
        if AppSettings.bool(.offlineMode) { route = .offline; return }
        if AppSettings.string(.connectionMode, default: "normal") == "proxy" /* && !CAInstalled */ {
            route = .certGate; return
        }
        route = .main
    }

    private func checkUpdate() async {
        if await Updater.checkIfDue() != nil {
            // present changelog sheet from MainView via notification
            NotificationCenter.default.post(name: .updateAvailable, object: nil)
        }
    }
}

struct SplashView: View {
    var onDone: (String?) -> Void
    var body: some View {
        VStack { ProgressView(); Text("MuseMobile").bold() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                onDone(nil)
            }
    }
}

struct CertGateView: View {
    var onDone: () -> Void; var onNormal: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text("Certificate Required").font(.title2).bold()
            Text("Proxy mode needs the MuseMobile CA. Export MuseMobile_CA.pem, install it in Settings > General > VPN & Device Management, then trust it.")
                .font(.footnote).multilineTextAlignment(.center)
            Button("Export .pem (Share Sheet)") { /* share proxy_ca */ }
            Button("Check") { onDone() }
            Button("Switch to Normal") {
                UserDefaults.standard.set("normal", forKey: AppSettings.Key.connectionMode.rawValue)
                onNormal()
            }
        }.padding().background(Color.black)
    }
}

extension Notification.Name { static let updateAvailable = Notification.Name("updateAvailable") }
