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
        // Don't lose the last second's lines when the app is suspended.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    private func saveNow() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        save()
    }

    private var saveTask: Task<Void, Never>?

    func log(_ message: String) {
        buffer.append(message, at: .now)
        // Saved at most once a second, so a burst of lines costs one write.
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.save()
        }
    }

    private func save() {
        saveTask = nil
        try? buffer.text().write(to: url, atomically: true, encoding: .utf8)
    }

    func clear() {
        saveTask?.cancel()
        saveTask = nil
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
        .safeAreaInset(edge: .bottom) {
            Text("Includes your computers' names and addresses, never passwords. Share it with whoever helps you troubleshoot.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
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
