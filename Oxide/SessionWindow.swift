import SwiftUI
import UIKit

/// One session in a window of its own. Closing the window disconnects it.
struct SessionWindow: View {
    let id: UUID?
    let library: HostLibrary
    let open: OpenSessions
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if let id, open.windowsRequested.contains(id), let entry = open.entry(id) {
            RemoteView(
                connection: entry.connection, host: entry.host,
                onNewPassword: { password, remember in
                    if remember, let host = entry.host { library.remember(password, for: host) }
                },
                onShowList: { showComputers() },
                onClose: {
                    open.close(id)
                    dismissWindow()
                })
                .background(WindowHook(title: entry.host?.displayName ?? entry.connection.peer.hostname,
                                       onClosed: { open.close(id) }))
                .onAppear {
                    // Late, after the session went back to the main window:
                    // it's this window's again, so it isn't shown twice.
                    if !entry.inWindow {
                        open.moveToWindow(id)
                        entry.connection.reveal()
                    }
                    open.windowAppeared(id)
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    #if targetEnvironment(macCatalyst)
                    // A Mac app isn't suspended: a tab in the back, a
                    // minimised or hidden window, only stops decoding.
                    if phase == .background { entry.connection.hide() } else { entry.connection.reveal() }
                    #else
                    switch phase {
                    case .background: entry.connection.enteredBackground()
                    case .active:
                        // It may come from the main window, where it was hidden.
                        entry.connection.reveal()
                        entry.connection.becameActive()
                    default: break
                    }
                    #endif
                }
        } else {
            // A window restored after a relaunch, or one whose session ended.
            #if targetEnvironment(macCatalyst)
            Color(uiColor: .sessionBackground)
                .task { dismissWindow() }
            #else
            // iOS doesn't close it (it may be the only window): it becomes a
            // list of computers instead of an empty screen.
            ContentView(library: library, open: open)
            #endif
        }
    }
}

extension SessionWindow {
    /// The list of computers: its window brought forward, or a new one.
    private func showComputers() {
        if let scene = open.mainScene, UIApplication.shared.openSessions.contains(scene) {
            UIApplication.shared.requestSceneSessionActivation(scene, userActivity: nil, options: nil)
        } else {
            openWindow(id: WindowID.computers)
        }
    }
}

/// The scene session of the window a view is in.
struct SceneReader: UIViewRepresentable {
    let onScene: (UISceneSession) -> Void

    func makeUIView(context: Context) -> ReaderView { ReaderView() }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onScene = onScene
        view.report()
    }

    final class ReaderView: UIView {
        var onScene: ((UISceneSession) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        func report() {
            if let session = window?.windowScene?.session { onScene?(session) }
        }
    }
}

/// Names the window after its computer, and tells when it's closed. On a Mac
/// the session windows join each other as tabs.
private struct WindowHook: UIViewRepresentable {
    let title: String
    let onClosed: () -> Void

    func makeUIView(context: Context) -> HookView {
        HookView()
    }

    func updateUIView(_ view: HookView, context: Context) {
        view.title = title
        view.onClosed = onClosed
    }

    final class HookView: UIView {
        var title = "" {
            didSet { if title != oldValue { showTitle() } }
        }
        var onClosed: (() -> Void)?
        private weak var watchedScene: UIScene?
        /// While the Mac window is being looked for, its title is a marker
        /// that nothing else may overwrite.
        private var marker: String?
        private weak var joinedWindow: UIWindow?

        private func showTitle() {
            guard marker == nil, let scene = window?.windowScene else { return }
            scene.title = title
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, let scene = window.windowScene else { return }
            showTitle()
            if watchedScene !== scene {
                if let watchedScene {
                    NotificationCenter.default.removeObserver(self, name: UIScene.didDisconnectNotification,
                                                              object: watchedScene)
                }
                watchedScene = scene
                NotificationCenter.default.addObserver(self, selector: #selector(sceneDisconnected),
                                                       name: UIScene.didDisconnectNotification, object: scene)
            }
            #if targetEnvironment(macCatalyst)
            // Once per window: a newer search replaces an older one.
            guard joinedWindow !== window else { return }
            joinedWindow = window
            let marker = "oxide-tab-\(UUID().uuidString)"
            self.marker = marker
            scene.title = marker
            MacTabs.find(marker) { [weak self] found in
                guard let self, self.marker == marker else { return }
                self.marker = nil
                self.showTitle()
                if let found { MacTabs.tab(found) }
            }
            #endif
        }

        /// The window was closed (or the app quit).
        @objc private func sceneDisconnected() {
            onClosed?()
        }
    }
}

#if targetEnvironment(macCatalyst)
/// Session windows as macOS window tabs. Mac Catalyst has no API for this;
/// AppKit's public NSWindow methods are reached at run time, and every step
/// is skipped if something isn't there. To find its NSWindow, the window
/// takes a unique title for a moment (AppKit shows the scene's title).
@MainActor
enum MacTabs {
    static let identifier = "com.ulfschnabel.duodesk.session"

    /// The NSWindow showing `marker` as its title, once AppKit has made it
    /// (a moment after the scene appears); nil after two seconds.
    static func find(_ marker: String, attempt: Int = 0, then done: @escaping (NSObject?) -> Void) {
        if let found = allWindows().first(where: { ($0.value(forKey: "title") as? String) == marker }) {
            done(found)
        } else if attempt < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                find(marker, attempt: attempt + 1, then: done)
            }
        } else {
            done(nil)
        }
    }

    /// Tabs a session window onto another visible one.
    static func tab(_ mine: NSObject) {
        mine.setValue(identifier, forKey: "tabbingIdentifier")
        mine.setValue(1, forKey: "tabbingMode")  // NSWindowTabbingModePreferred
        guard let other = sessionWindows().first(where: { $0 !== mine && isVisible($0) }),
              (mine.value(forKey: "tabbedWindows") as? [NSObject])?.contains(where: { $0 === other }) != true
        else { return }
        let selector = NSSelectorFromString("addTabbedWindow:ordered:")
        guard other.responds(to: selector) else { return }
        typealias AddTab = @convention(c) (NSObject, Selector, NSObject, Int) -> Void
        let add = unsafeBitCast(other.method(for: selector), to: AddTab.self)
        add(other, selector, mine, 1)  // NSWindowAbove
        mine.perform(NSSelectorFromString("makeKeyAndOrderFront:"), with: nil)
    }

    private static func allWindows() -> [NSObject] {
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?
                .value(forKey: "sharedApplication") as? NSObject,
              let windows = app.value(forKey: "windows") as? [NSObject]
        else { return [] }
        return windows
    }

    private static func sessionWindows() -> [NSObject] {
        allWindows().filter {
            $0.responds(to: NSSelectorFromString("tabbingIdentifier"))
                && ($0.value(forKey: "tabbingIdentifier") as? String) == identifier
        }
    }

    private static func isVisible(_ window: NSObject) -> Bool {
        (window.value(forKey: "visible") as? Bool) ?? false
    }
}
#endif
