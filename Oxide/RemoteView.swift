import SwiftUI

struct RemoteView: View {
    let connection: RemoteConnection
    /// The saved name, or nil to show the host's own name.
    var title: String?
    var onClose: () -> Void
    @AppStorage(SettingsKey.matchResolution) private var matchResolution = true
    @AppStorage(SettingsKey.textSize) private var textSize: TextSize = .balanced
    @State private var showSettings = false
    @State private var showHelp = false

    var body: some View {
        let input = connection.input
        ZStack(alignment: .top) {
            RemoteScreen(connection: connection, input: input)
                .ignoresSafeArea(edges: [.top, .horizontal])
            HStack(spacing: 8) {
                Text(title ?? connection.peer.hostname)
                    .font(.footnote.weight(.semibold))
                if let status = connection.status {
                    Text(status).font(.footnote)
                }
                Spacer()
                Button(input.mode == .trackpad ? "Trackpad" : "Touch",
                       systemImage: input.mode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left") {
                    input.mode = input.mode == .trackpad ? .touch : .trackpad
                }
                Button("Help", systemImage: "questionmark") { showHelp = true }
                Button("Settings", systemImage: "gearshape") { showSettings = true }
                Button("Keyboard", systemImage: input.keyboardShown ? "keyboard.chevron.compact.down" : "keyboard") {
                    input.keyboardShown.toggle()
                }
                Button("Disconnect", systemImage: "xmark") {
                    Task {
                        await connection.disconnect()
                        onClose()
                    }
                }
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
        .onChange(of: matchResolution) { connection.resolutionSettingsChanged() }
        .onChange(of: textSize) { connection.resolutionSettingsChanged() }
    }
}
