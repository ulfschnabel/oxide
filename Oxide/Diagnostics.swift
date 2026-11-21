import OxideKit
import SwiftUI
import UIKit

/// What happened during recent connections, for bug reports. Kept in a file
/// so it survives a crash or relaunch. Never holds passwords.
@MainActor @Observable
final class Diagnostics {
    static let shared = Diagnostics()

    private(set) var buffer: LogBuffer
    private let url = URL.cachesDirectory.appending(path: "diagnostics.log")

    private init() {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        buffer = LogBuffer(text: text, capacity: 600)
    }

    func log(_ message: String) {
        buffer.append(message, at: .now)
        try? buffer.text().write(to: url, atomically: true, encoding: .utf8)
    }

    func clear() {
        buffer.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    /// The log with what's needed to read it: app version, device, system.
    var report: String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
        var size = utsname()
        uname(&size)
        let model = withUnsafeBytes(of: size.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let header = "Oxide \(version), \(model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        return header + "\n\n" + buffer.text()
    }
}

/// Shorthand for the shared diagnostics log.
@MainActor func diag(_ message: String) {
    Diagnostics.shared.log(message)
}

struct DiagnosticsView: View {
    @State private var diagnostics = Diagnostics.shared

    var body: some View {
        ScrollView {
            Text(diagnostics.buffer.lines.isEmpty ? "Nothing logged yet." : diagnostics.report)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .defaultScrollAnchor(.bottom)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ShareLink(item: diagnostics.report) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Menu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = diagnostics.report }
                    Button("Clear", systemImage: "trash", role: .destructive) { diagnostics.clear() }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    }
}
