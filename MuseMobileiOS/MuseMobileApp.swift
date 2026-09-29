import SwiftUI
import os

@main
struct MuseMobileApp: App {
    init() {
        AppSettings.registerDefaults()
        let bootLog = Logger(subsystem: "com.musemobile.ios", category: "boot")
        bootLog.info("MuseMobileBootOK")
        os_log("MuseMobileBootOK")
    }
    var body: some Scene {
        WindowGroup { RootView() }
    }
}
