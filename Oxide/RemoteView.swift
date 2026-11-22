import OxideKit
import SwiftUI

struct RemoteView: View {
    let connection: RemoteConnection
    /// The saved computer, or nil (development auto-connect).
    var host: SavedHost?
    /// A new password the user typed after a refused reconnect, and whether to keep it.
    var onNewPassword: (String, Bool) -> Void = { _, _ in }
    var onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.matchResolution) private var matchResolution = true
    @AppStorage(SettingsKey.textSize) private var textSize: TextSize = .balanced
    @State private var showSettings = false
    @State private var showHelp = false
    @State private var askPassword = false

    var body: some View {
        let input = connection.input
        ZStack(alignment: .top) {
            RemoteScreen(connection: connection, input: input)
                .ignoresSafeArea(edges: [.top, .horizontal])
            if isReconnecting {
                reconnecting
            }
            HStack(spacing: 8) {
                Text(host?.displayName ?? connection.peer.hostname)
                    .font(.footnote.weight(.semibold))
                if let status = connection.status {
                    Text(status).font(.footnote)
                }
                Spacer()
                if input.viewport.isZoomed {
                    Button("Fit", systemImage: "arrow.down.right.and.arrow.up.left") {
                        input.viewport.reset()
                    }
                }
                Button(input.mode == .trackpad ? "Trackpad" : "Touch",
                       systemImage: input.mode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left") {
                    input.mode = input.mode == .trackpad ? .touch : .trackpad
                }
                Button("Help", systemImage: "questionmark") { showHelp = true }
                Button("Settings", systemImage: "gearshape") { showSettings = true }
                Button("Keyboard", systemImage: input.keyboardShown ? "keyboard.chevron.compact.down" : "keyboard") {
                    input.keyboardShown.toggle()
                }
                Button("Disconnect", systemImage: "xmark") { close() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .padding(.horizontal)
            .foregroundStyle(.white)
        }
        .background(.black)
        .statusBarHidden()
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                HelpView().toolbar {
                    Button("Done", systemImage: "checkmark") { showHelp = false }
                }
            }
        }
        .alert(failure?.cause.title ?? "", isPresented: showFailure, presenting: failure) { problem in
            if problem == .login(.wrongPassword), host != nil {
                Button("Enter Password") { askPassword = true }
            } else {
                Button("Retry") { connection.retry() }
            }
            Button("Back to Computers", role: .cancel) { close() }
        } message: { problem in
            Text(problem.message)
        }
        .sheet(isPresented: $askPassword) {
            if let host {
                PasswordPrompt(host: host, wrong: true) { password, remember in
                    askPassword = false
                    onNewPassword(password, remember)
                    connection.retry(password: password)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: connection.enteredBackground()
            case .active: connection.becameActive()
            default: break
            }
        }
        .onChange(of: matchResolution) { connection.resolutionSettingsChanged() }
        .onChange(of: textSize) { connection.resolutionSettingsChanged() }
    }

    private var isReconnecting: Bool {
        switch connection.phase {
        case .reconnecting, .paused: true
        default: false
        }
    }

    /// Over the last picture, dimmed: it's not live.
    private var reconnecting: some View {
        ZStack {
            Color.black.opacity(0.45)
            HStack(spacing: 12) {
                ProgressView()
                Text("Reconnecting…")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .glassEffect(in: .capsule)
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
        // Catches touches: there's no session to send them to. The toolbar
        // stays usable above it.
        .contentShape(Rectangle())
    }

    private var failure: ConnectionProblem? {
        if case .failed(let problem) = connection.phase { problem } else { nil }
    }

    /// Up while the connection has given up, unless the password sheet is.
    private var showFailure: Binding<Bool> {
        Binding(get: { failure != nil && !askPassword }, set: { _ in })
    }

    private func close() {
        Task {
            await connection.disconnect()
            onClose()
        }
    }
}
