import SwiftUI

@main
struct MuseMobileApp: App {
    init() { AppSettings.registerDefaults() }
    var body: some Scene {
        WindowGroup { RootView() }
    }
}
