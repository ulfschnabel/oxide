import SwiftUI

@main
struct OxideApp: App {
    init() { SettingsKey.register() }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
