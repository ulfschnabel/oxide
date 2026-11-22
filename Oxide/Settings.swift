import SwiftUI

/// How large the remote desktop's text looks when its resolution follows
/// this screen: the target is the window's size in points times this factor.
enum TextSize: String, CaseIterable, Identifiable {
    case larger, balanced, sharp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .larger: "Larger"
        case .balanced: "Balanced"
        case .sharp: "Sharp"
        }
    }

    func factor(screenScale: CGFloat) -> CGFloat {
        switch self {
        case .larger: 1
        case .balanced: 1.5
        case .sharp: screenScale  // one host pixel per screen pixel
        }
    }
}

enum InputMode: String, CaseIterable, Identifiable {
    case trackpad, buttons, touch

    var id: String { rawValue }
    var title: String {
        switch self {
        case .trackpad: "Trackpad"
        case .buttons: "Trackpad + buttons"
        case .touch: "Touch"
        }
    }
}

enum SettingsKey {
    static let matchResolution = "matchResolution"
    static let textSize = "textSize"
    static let inputMode = "inputMode"
    static let pointerSpeed = "pointerSpeed"
    static let scrollSpeed = "scrollSpeed"
    /// Seconds a session stays up in the background; 0 pauses it at once.
    static let backgroundGrace = "backgroundGrace"

    static func register() {
        UserDefaults.standard.register(defaults: [
            matchResolution: true,
            textSize: TextSize.balanced.rawValue,
            inputMode: InputMode.trackpad.rawValue,
            pointerSpeed: 1.5,
            scrollSpeed: 2.0,
            backgroundGrace: 30.0,
        ])
    }
}

struct SettingsView: View {
    @AppStorage(SettingsKey.matchResolution) private var matchResolution = true
    @AppStorage(SettingsKey.textSize) private var textSize: TextSize = .balanced
    @AppStorage(SettingsKey.inputMode) private var inputMode: InputMode = .trackpad
    @AppStorage(SettingsKey.pointerSpeed) private var pointerSpeed = 1.5
    @AppStorage(SettingsKey.scrollSpeed) private var scrollSpeed = 2.0
    @AppStorage(SettingsKey.backgroundGrace) private var backgroundGrace = 30.0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Match the remote screen to this device", isOn: $matchResolution)
                    Picker("Text size", selection: $textSize) {
                        ForEach(TextSize.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(!matchResolution)
                } header: {
                    Text("Resolution")
                } footer: {
                    Text("""
                        When you connect, rotate, fold or resize the window, the remote computer switches \
                        to the screen mode that best fits this device. Its original resolution comes back \
                        when you disconnect. Only modes the remote display offers can be used.
                        """)
                }

                Section("Pointer") {
                    Picker("Start in", selection: $inputMode) {
                        ForEach(InputMode.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Trackpad speed") {
                        Slider(value: $pointerSpeed, in: 0.5...4)
                    }
                    LabeledContent("Scroll speed") {
                        Slider(value: $scrollSpeed, in: 0.5...6)
                    }
                }

                Section {
                    Picker("Stay connected", selection: $backgroundGrace) {
                        Text("Off").tag(0.0)
                        Text("10 seconds").tag(10.0)
                        Text("30 seconds").tag(30.0)
                    }
                } header: {
                    Text("In the Background")
                } footer: {
                    Text("""
                        How long the session stays up while you're in another app. After that it pauses, \
                        and reconnects when you come back. iOS allows about 30 seconds.
                        """)
                }

                Section {
                    NavigationLink {
                        HelpView()
                    } label: {
                        Label("Gestures & keyboard", systemImage: "questionmark.circle")
                    }
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                    Link(destination: URL(string: "https://github.com/ulfschnabel/oxide")!) {
                        Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!) {
                        Label("License: GNU AGPL v3", systemImage: "doc.text")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("""
                        Oxide connects directly to computers running RustDesk with direct IP access, \
                        on your network or VPN. The connection isn't encrypted: don't use it over the open internet.

                        Oxide is free software and is not affiliated with RustDesk or Purslane Ltd. \
                        It includes RustDesk's protocol definitions, licensed under the AGPL, \
                        and uses SwiftProtobuf (Apache License 2.0).

                        Copyright © 2026 Ulf Schnabel
                        """)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
