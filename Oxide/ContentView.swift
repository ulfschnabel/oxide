import OxideKit
import SwiftUI

/// The saved computers, or the remote screen while connected.
struct ContentView: View {
    @State private var library = HostLibrary()
    @State private var session: ActiveSession?

    struct ActiveSession {
        let host: SavedHost?
        let connection: RemoteConnection
    }

    var body: some View {
        if let session {
            RemoteView(connection: session.connection, host: session.host, onNewPassword: { password, remember in
                if remember, let host = session.host { library.remember(password, for: host) }
            }) {
                self.session = nil
            }
        } else {
            HomeView(library: library) { host, connection in
                session = ActiveSession(host: host, connection: connection)
            }
        }
    }
}

struct HomeView: View {
    let library: HostLibrary
    var onConnected: (SavedHost?, RemoteConnection) -> Void

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
    }

    private var connecting: UUID? { attempt?.host.id }

    struct AskPassword: Identifiable {
        let host: SavedHost
        let wrong: Bool
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
                    connect(ask.host, password: password)
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
                    HostRow(host: host, connecting: connecting == host.id, hasPassword: library.hasPassword(host))
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

    private func start(_ host: SavedHost) {
        guard attempt == nil else { return }
        if let password = library.password(for: host) {
            connect(host, password: password)
        } else {
            askPassword = AskPassword(host: host, wrong: false)
        }
    }

    private func connect(_ host: SavedHost, password: String) {
        guard attempt == nil else { return }
        let current = Attempt(host: host)
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
                onConnected(host, connection)
            case .failure(ConnectionProblem.login(.wrongPassword)):
                askPassword = AskPassword(host: host, wrong: true)
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
            onConnected(nil, connection)
        }
    }
    #endif
}

private struct HostRow: View {
    let host: SavedHost
    let connecting: Bool
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
