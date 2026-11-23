import OxideKit
import SwiftUI

/// The saved computers, or the remote screen of one of the open sessions
/// (those not in a window of their own).
struct ContentView: View {
    let library: HostLibrary
    let open: OpenSessions
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    /// This window's claim on showing the main window's sessions: only one
    /// window may (iPadOS lets the user make more of them).
    @State private var token = UUID()
    private var isMain: Bool { open.mainWindow == token }

    var body: some View {
        Group {
            if isMain, let top = open.shown, let bottom = open.secondShown {
                // Two at once: stacked upright, side by side across.
                GeometryReader { geo in
                    let stacked = geo.size.height >= geo.size.width
                    let layout = stacked ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
                    layout {
                        pane(top, 0)
                        pane(bottom, 1)
                    }
                }
                // The panes keep their size, and their remote resolution, when
                // the on-screen keyboard comes up.
                .ignoresSafeArea(.keyboard)
                .background(Color(uiColor: .sessionBackground))
                .statusBarHidden()
            } else if isMain, let session = open.shown {
                RemoteView(
                    connection: session.connection, host: session.host, position: open.ring.position,
                    onNewPassword: { password, remember in
                        if remember, let host = session.host { library.remember(password, for: host) }
                    },
                    onSwitch: { offset in
                        // The outgoing view must already carry the new slide
                        // direction when it's removed: set it first, switch next turn.
                        open.prepareStep(offset)
                        Task { withAnimation(.snappy) { open.step(offset) } }
                    },
                    onShowList: { open.showList() },
                    onClose: { open.close(session.id) },
                    canSplit: open.canSplit,
                    onToggleSplit: { open.split() })
                    .id(session.id)
                    .transition(.push(from: open.lastStep < 0 ? .leading : .trailing))
            } else {
                HomeView(library: library, openHosts: open.hostIDs,
                         hasOpenSessions: isMain && !open.inMainWindow.isEmpty,
                         canOpenWindows: Windows.available,
                         // A second list window has no sessions of its own: it opens windows.
                         windowByDefault: Windows.byDefault || (Windows.available && !isMain),
                         onConnected: { host, connection, inWindow in
                             let id = open.add(host: host, connection: connection, inWindow: inWindow)
                             if inWindow { openInWindow(id) }
                         },
                         onShowOpen: { host, inWindow in
                             if let id = host?.id, open.isInWindow(id) || inWindow {
                                 open.moveToWindow(id)
                                 openInWindow(id)
                             } else {
                                 open.show(host?.id)
                             }
                         },
                         onDeleted: { host in open.close(host.id) })
            }
        }
        .background(SceneReader { if isMain { open.mainScene = $0 } })
        .onAppear { open.claimMainWindow(token) }
        .onChange(of: open.mainWindow) { _, main in
            if main == nil { open.claimMainWindow(token) }
        }
        // Where windows show one at a time (a phone keeping several, like the
        // Duo), the one on screen is the main one.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active, !Windows.available { open.takeMainWindow(token) }
        }
        .onDisappear { open.releaseMainWindow(token) }
        .task { diag("windows of their own: \(Windows.available ? "yes" : "no")") }
        // Every session of the main window goes to the background and comes
        // back, not only the one on screen. (Session windows see to their own.)
        .onChange(of: scenePhase) { _, phase in
            guard isMain else { return }
            for session in open.inMainWindow {
                switch phase {
                case .background: session.connection.enteredBackground()
                case .active: session.connection.becameActive()
                default: break
                }
            }
        }
    }
}

extension ContentView {
    /// One of two panes.
    fileprivate func pane(_ session: OpenSessions.Entry, _ index: Int) -> some View {
        RemoteView(
            connection: session.connection, host: session.host,
            onNewPassword: { password, remember in
                if remember, let host = session.host { library.remember(password, for: host) }
            },
            onSwitch: { offset in open.step(offset, pane: index) },
            onShowList: { open.showList() },
            onClose: { open.close(session.id) },
            isSplit: true,
            onToggleSplit: { open.unsplit() },
            isActivePane: open.activePane == index,
            onActivate: { if open.activePane != index { open.activePane = index } })
            // Equal halves, whatever each pane's content would like.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(session.id)
    }

    /// Opens the session's window. Where no window appears (a device that
    /// turns out to have only one), the session comes back here.
    fileprivate func openInWindow(_ id: UUID) {
        open.windowRequested(id)
        openWindow(value: id)
        Task {
            try? await Task.sleep(for: .seconds(2))
            if !open.hasWindow(id) {
                diag("no window appeared for the session: shown here instead")
                open.moveToMainWindow(id)
            }
        }
    }
}

/// Where sessions can have windows of their own: a Mac (always) and an iPad
/// (on request). A phone, even one that keeps several windows (the Duo),
/// shows one at a time: two sessions go side by side in one window instead.
@MainActor
enum Windows {
    static var available: Bool {
        UIApplication.shared.supportsMultipleScenes && UIDevice.current.userInterfaceIdiom != .phone
    }
    static var byDefault: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }
}

/// The remote sessions that are open, for the whole app. Each is either in
/// the main window, which shows one at a time (the others stay connected but
/// don't decode video), or in a window of its own.
@MainActor @Observable
final class OpenSessions {
    struct Entry: Identifiable {
        let id: UUID
        let host: SavedHost?
        let connection: RemoteConnection
        var inWindow = false
    }

    private(set) var ring = SessionRing<UUID>()
    private var entries: [UUID: Entry] = [:]
    /// The list is on screen while sessions stay open.
    private(set) var listShown = false
    /// The direction of the last switch, for the slide.
    private(set) var lastStep = 1

    var shown: Entry? { listShown ? nil : ring.current.flatMap { entries[$0] } }
    /// The session in the second pane, when two are on screen.
    var secondShown: Entry? { listShown ? nil : ring.second.flatMap { entries[$0] } }
    /// Of two panes, the one keys go to (0: the first).
    var activePane = 0

    var canSplit: Bool { ring.ids.count > 1 && ring.second == nil }

    /// Shows the next session in a second pane.
    func split() {
        guard let id = ring.split() else { return }
        activePane = 0
        entries[id]?.connection.reveal()
    }

    /// Back to one session on screen: the first pane's.
    func unsplit() {
        secondShown?.connection.hide()
        ring.unsplit()
        activePane = 0
    }

    /// A three-finger swipe in one of two panes.
    func step(_ offset: Int, pane: Int) {
        let old = pane == 0 ? ring.current : ring.second
        guard let new = ring.step(offset, pane: pane) else { return }
        old.flatMap { entries[$0] }?.connection.hide()
        entries[new]?.connection.reveal()
    }
    var all: [Entry] { Array(entries.values) }
    var hostIDs: Set<UUID> { Set(entries.values.compactMap(\.host?.id)) }

    /// The session's id, which its window (if any) is opened with.
    @discardableResult
    func add(host: SavedHost?, connection: RemoteConnection, inWindow: Bool = false) -> UUID {
        let id = host?.id ?? UUID()
        entries[id] = Entry(id: id, host: host, connection: connection, inWindow: inWindow)
        if !inWindow { show(id) }
        return id
    }

    func entry(_ id: UUID) -> Entry? { entries[id] }

    /// The window that shows the main window's sessions, and its scene (to
    /// bring it forward from a session window).
    private(set) var mainWindow: UUID?
    @ObservationIgnored var mainScene: UISceneSession?

    /// A list window becomes the main one if there's none: on launch, or
    /// when the main window closed and this one is left.
    func claimMainWindow(_ token: UUID) {
        guard mainWindow == nil else { return }
        mainWindow = token
        if !listShown {
            shown?.connection.reveal()
            secondShown?.connection.reveal()
        }
    }

    func takeMainWindow(_ token: UUID) {
        mainWindow = token
    }

    func releaseMainWindow(_ token: UUID) {
        guard mainWindow == token else { return }
        // Off screen until another window takes over.
        shown?.connection.hide()
        secondShown?.connection.hide()
        mainWindow = nil
    }

    /// Sessions a window was asked for in this run, and those whose window
    /// has appeared. Only those windows show a session: a window restored
    /// from an earlier run never takes one over.
    private(set) var windowsRequested: Set<UUID> = []
    private var windowsShown: Set<UUID> = []

    func windowRequested(_ id: UUID) { windowsRequested.insert(id) }

    func windowAppeared(_ id: UUID) { windowsShown.insert(id) }
    func hasWindow(_ id: UUID) -> Bool { windowsShown.contains(id) }

    /// A session whose window didn't appear goes back to the main window.
    func moveToMainWindow(_ id: UUID) {
        guard var entry = entries[id], entry.inWindow else { return }
        entry.inWindow = false
        entries[id] = entry
        show(id)
    }

    func isInWindow(_ id: UUID) -> Bool { entries[id]?.inWindow ?? false }

    /// Takes a session out of the main window, for a window of its own.
    func moveToWindow(_ id: UUID) {
        guard var entry = entries[id], !entry.inWindow else { return }
        if ring.current == id || ring.second == id, !listShown { entry.connection.hide() }
        entry.inWindow = true
        entries[id] = entry
        ring.close(id)
        if !listShown { shown?.connection.reveal() }
        if ring.ids.isEmpty { listShown = false }
    }

    /// The sessions shown in the main window, one at a time.
    var inMainWindow: [Entry] { ring.ids.compactMap { entries[$0] } }

    /// Shows an open session: the one for `id`, or the last one shown.
    func show(_ id: UUID?) {
        let target = id ?? ring.current
        guard let target, entries[target] != nil else { return }
        if target != ring.current { shown?.connection.hide() }
        lastStep = 1
        ring.open(target)
        listShown = false
        entries[target]?.connection.reveal()
        secondShown?.connection.reveal()
    }

    /// Sets the slide direction for the switch that follows.
    func prepareStep(_ offset: Int) {
        lastStep = offset
    }

    func step(_ offset: Int) {
        guard let old = shown, let new = ring.step(offset) else { return }
        diag("switched to session \((ring.position?.index ?? 0) + 1) of \(ring.ids.count)")
        lastStep = offset
        old.connection.hide()
        entries[new]?.connection.reveal()
    }

    func showList() {
        shown?.connection.hide()
        secondShown?.connection.hide()
        listShown = true
    }

    /// Disconnects a session (if it's open) and shows the next one.
    func close(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        windowsShown.remove(id)
        windowsRequested.remove(id)
        Task { await entry.connection.disconnect() }
        ring.close(id)
        if !listShown {
            shown?.connection.reveal()
            secondShown?.connection.reveal()
        }
        if ring.second == nil { activePane = 0 }
        if ring.ids.isEmpty { listShown = false }
    }
}

struct HomeView: View {
    let library: HostLibrary
    /// Saved computers with an open session.
    var openHosts: Set<UUID> = []
    var hasOpenSessions = false
    /// Sessions can have windows of their own (Mac, iPad).
    var canOpenWindows = false
    /// Every session gets its own window (Mac: shown as tabs).
    var windowByDefault = false
    /// A new session, and whether it goes in a window of its own.
    var onConnected: (SavedHost?, RemoteConnection, Bool) -> Void
    /// Back to an open session: that computer's, or nil for the last one
    /// shown; true moves it to a window of its own.
    var onShowOpen: (SavedHost?, Bool) -> Void = { _, _ in }
    /// A computer was deleted; its session, if open, goes too.
    var onDeleted: (SavedHost) -> Void = { _ in }

    @State private var editing: SavedHost?
    @State private var adding = false
    @State private var showSettings = false
    @State private var showHelp = false
    /// The connect in progress. Each attempt has its own id, so an attempt
    /// that was cancelled can't touch the state of a newer one.
    @State private var attempt: Attempt?
    @State private var connectTask: Task<Void, Never>?
    @State private var askPassword: AskPassword?
    @State private var failure: Failure?
    @State private var deleting: SavedHost?

    struct Attempt: Equatable {
        let id = UUID()
        let host: SavedHost
        let inWindow: Bool
    }

    private var connecting: UUID? { attempt?.host.id }

    struct AskPassword: Identifiable {
        let host: SavedHost
        let wrong: Bool
        var inWindow = false
        var id: UUID { host.id }
    }

    struct Failure: Identifiable {
        let host: SavedHost
        let message: String
        var id: UUID { host.id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.hosts.isEmpty {
                    emptyState
                } else {
                    hostList
                }
            }
            .navigationTitle("Computers")
            // Pinned, so it stays reachable however long the list is.
            .safeAreaInset(edge: .bottom) {
                if let attempt {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Connecting to \(attempt.host.displayName)…")
                            .lineLimit(1)
                        Spacer()
                        Button("Cancel", role: .cancel) { cancel() }
                            .buttonStyle(.glass)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(in: .capsule)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .toolbar {
                if hasOpenSessions {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Open Sessions", systemImage: "rectangle.stack.fill") { onShowOpen(nil, false) }
                            .disabled(attempt != nil)
                    }
                }
                // Nothing else opens while connecting: its outcome (a password
                // prompt or an error) needs to be able to show.
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Computer", systemImage: "plus") { adding = true }
                        .disabled(attempt != nil)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                        .disabled(attempt != nil)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Gestures & Keyboard", systemImage: "questionmark.circle") { showHelp = true }
                        .disabled(attempt != nil)
                }
            }
            .sheet(isPresented: $adding) { HostEditor(library: library, host: nil) }
            .sheet(item: $editing) { HostEditor(library: library, host: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showHelp) {
                NavigationStack {
                    HelpView().toolbar {
                        Button("Done", systemImage: "checkmark") { showHelp = false }
                    }
                }
            }
            .sheet(item: $askPassword) { ask in
                PasswordPrompt(host: ask.host, wrong: ask.wrong) { password, remember in
                    askPassword = nil
                    if remember { library.remember(password, for: ask.host) }
                    connect(ask.host, password: password, inWindow: ask.inWindow)
                }
            }
            .alert(item: $failure) { failure in
                Alert(title: Text("Couldn't connect to \(failure.host.displayName)"),
                      message: Text(failure.message),
                      primaryButton: .default(Text("Edit")) { editing = failure.host },
                      secondaryButton: .cancel(Text("OK")))
            }
            .confirmationDialog(
                "Delete \(deleting?.displayName ?? "")?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let deleting else { return }
                    if attempt?.host.id == deleting.id { cancel() }
                    onDeleted(deleting)
                    library.remove(deleting)
                }
            } message: {
                Text("Its saved password is removed too.")
            }
        }
        #if DEBUG
        .task { await debugAutoConnect() }
        #endif
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Computers Yet", systemImage: "desktopcomputer")
        } description: {
            Text("""
                Add a computer that runs RustDesk with direct IP access turned on \
                (RustDesk → Settings → Security → Enable direct IP access). \
                It needs to be on your network or reachable over your VPN.
                """)
        } actions: {
            Button("Add Computer") { adding = true }
                .buttonStyle(.glassProminent)
        }
    }

    private var hostList: some View {
        List {
            if let error = library.loadError {
                Text(error).foregroundStyle(.red)
            }
            ForEach(library.hosts) { host in
                Button {
                    start(host)
                } label: {
                    HostRow(host: host, connecting: connecting == host.id, open: openHosts.contains(host.id),
                            hasPassword: library.hasPassword(host))
                }
                .disabled(connecting != nil && connecting != host.id)
                .swipeActions {
                    // While connecting, the Cancel button is the only action.
                    if attempt == nil {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = host }
                        Button("Edit", systemImage: "pencil") { editing = host }
                    }
                }
                .contextMenu {
                    if attempt == nil {
                        Button("Connect", systemImage: "play.fill") { start(host) }
                        if canOpenWindows && !windowByDefault {
                            Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                                start(host, inWindow: true)
                            }
                        }
                        Button("Edit", systemImage: "pencil") { editing = host }
                        if library.hasPassword(host) {
                            Button("Forget Password", systemImage: "key.slash") { library.forgetPassword(of: host) }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = host }
                    }
                }
            }
        }
    }

    private func start(_ host: SavedHost, inWindow: Bool? = nil) {
        guard attempt == nil else { return }
        let inWindow = inWindow ?? windowByDefault
        if openHosts.contains(host.id) {
            onShowOpen(host, inWindow)
            return
        }
        if let password = library.password(for: host) {
            connect(host, password: password, inWindow: inWindow)
        } else {
            askPassword = AskPassword(host: host, wrong: false, inWindow: inWindow)
        }
    }

    private func connect(_ host: SavedHost, password: String, inWindow: Bool) {
        guard attempt == nil else { return }
        let current = Attempt(host: host, inWindow: inWindow)
        attempt = current
        connectTask = Task {
            let result: Result<RemoteConnection, Error>
            do {
                result = .success(try await RemoteConnection.open(host: host.address, password: password))
            } catch {
                result = .failure(error)
            }
            // Cancelled, or replaced by a newer attempt: leave no trace.
            guard attempt == current, !Task.isCancelled else {
                if case .success(let connection) = result { await connection.disconnect() }
                return
            }
            attempt = nil
            connectTask = nil
            switch result {
            case .success(let connection):
                library.markConnected(host)
                onConnected(host, connection, inWindow)
            case .failure(ConnectionProblem.login(.wrongPassword)):
                askPassword = AskPassword(host: host, wrong: true, inWindow: inWindow)
            case .failure(is CancellationError):
                break
            case .failure(let error):
                diag("shown to the user: \(error.localizedDescription)")
                failure = Failure(host: host, message: error.localizedDescription)
            }
        }
    }

    private func cancel() {
        if attempt != nil { diag("connect cancelled") }
        connectTask?.cancel()
        connectTask = nil
        attempt = nil
    }

    #if DEBUG
    /// Development: `-lastHost H -password P -autoConnect YES` connects on launch, once.
    @MainActor private static var autoConnected = false

    private func debugAutoConnect() async {
        let d = UserDefaults.standard
        guard d.bool(forKey: "autoConnect"), !Self.autoConnected,
              let address = d.string(forKey: "lastHost"), let password = d.string(forKey: "password")
        else { return }
        Self.autoConnected = true
        if let connection = try? await RemoteConnection.open(host: address, password: password) {
            onConnected(nil, connection, windowByDefault)
        }
    }
    #endif
}

private struct HostRow: View {
    let host: SavedHost
    let connecting: Bool
    let open: Bool
    let hasPassword: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                // Explicit colours: a list button would tint its label.
                Text(host.displayName).font(.headline).foregroundStyle(Color.primary)
                Text(host.address).font(.subheadline).foregroundStyle(Color.secondary)
                if let last = host.lastConnected {
                    Text("Last connected \(last, format: .relative(presentation: .named))")
                        .font(.caption).foregroundStyle(Color.secondary.opacity(0.7))
                }
            }
            Spacer()
            if connecting {
                ProgressView()
            } else if open {
                Label("Open", systemImage: "circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Session open")
            } else if host.passwordKind == .oneTime {
                Image(systemName: "key.viewfinder").foregroundStyle(.secondary)
                    .accessibilityLabel("Asks for the one-time password")
            } else if !hasPassword {
                Image(systemName: "key").foregroundStyle(.secondary)
                    .accessibilityLabel("Asks for the password")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
