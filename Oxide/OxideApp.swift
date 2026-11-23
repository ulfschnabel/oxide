import SwiftUI

@main
struct OxideApp: App {
    /// Shared by every window: one list of computers, one set of open sessions.
    @State private var library: HostLibrary
    @State private var open = OpenSessions()

    init() {
        SettingsKey.register()
        _library = State(initialValue: HostLibrary())
    }

    var body: some Scene {
        WindowGroup(id: WindowID.computers) {
            ContentView(library: library, open: open)
        }
        // A session in a window of its own: every session on a Mac (shown
        // as tabs), one opened with "Open in New Window" on an iPad.
        WindowGroup("Session", for: UUID.self) { $id in
            SessionWindow(id: id, library: library, open: open)
        }
    }
}

enum WindowID {
    static let computers = "computers"
}
