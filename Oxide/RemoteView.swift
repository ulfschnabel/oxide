import OxideKit
import SwiftUI

struct RemoteView: View {
    let connection: RemoteConnection
    /// The saved computer, or nil (development auto-connect).
    var host: SavedHost?
    /// This session's place among the open ones.
    var position: (index: Int, count: Int)?
    /// A new password the user typed after a refused reconnect, and whether to keep it.
    var onNewPassword: (String, Bool) -> Void = { _, _ in }
    /// Three-finger swipe: +1 next session, -1 previous.
    var onSwitch: (Int) -> Void = { _ in }
    /// The list of computers, with this session left open.
    var onShowList: () -> Void = {}
    var onClose: () -> Void
    @AppStorage(SettingsKey.matchResolution) private var matchResolution = true
    @AppStorage(SettingsKey.textSize) private var textSize: TextSize = .balanced
    @State private var showSettings = false
    @State private var showHelp = false
    @State private var askPassword = false

    var body: some View {
        let input = connection.input
        ZStack(alignment: .top) {
            RemoteScreen(connection: connection, input: input, onSwitch: onSwitch)
                .ignoresSafeArea(edges: [.top, .horizontal])
            if isReconnecting {
                waiting("Reconnecting…")
            } else if connection.holdingPicture {
                // The host is changing its resolution to fit this screen.
                waiting("Connecting…")
            }
            HStack(spacing: 8) {
                Button("Computers", systemImage: "rectangle.stack") { onShowList() }
                // The whole name, or none on a narrow upright screen where
                // the buttons need the room.
                ViewThatFits(in: .horizontal) {
                    Text(host?.displayName ?? connection.peer.hostname)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                if let position, position.count > 1 {
                    Text("\(position.index + 1) of \(position.count)")
                        .font(.footnote.monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityLabel("Session \(position.index + 1) of \(position.count); swipe with three fingers to switch")
                }
                if let status = connection.status {
                    Text(status).font(.footnote)
                }
                Spacer()
                if input.viewport.isZoomed {
                    Button("Fit", systemImage: "arrow.down.right.and.arrow.up.left") {
                        input.viewport.reset()
                    }
                }
                Button(modeTitle, systemImage: modeSymbol) { input.cycleMode() }
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
        .onChange(of: matchResolution) { connection.resolutionSettingsChanged() }
        .onChange(of: textSize) { connection.resolutionSettingsChanged() }
    }

    private var modeTitle: String {
        switch connection.input.mode {
        case .trackpad: "Trackpad"
        case .buttons: "Trackpad + buttons"
        case .touch: "Touch"
        }
    }

    private var modeSymbol: String {
        switch connection.input.mode {
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .buttons: "computermouse"
        case .touch: "hand.point.up.left"
        }
    }

    private var isReconnecting: Bool {
        switch connection.phase {
        case .reconnecting, .paused: true
        default: false
        }
    }

    /// Over the last picture, dimmed: it's not live.
    private func waiting(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.45)
            HStack(spacing: 12) {
                ProgressView()
                Text(text)
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

    /// The owner disconnects it (and shows the next open session).
    private func close() {
        onClose()
    }
}
