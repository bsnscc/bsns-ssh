import SwiftUI

/// A local, on-device history of commands you've run — the privacy-respecting
/// counterpart to cloud "AI autocomplete": entries come from your own past
/// commands, nothing is uploaded. Stays on the device (deliberately not synced).
/// Thread-safe: `TerminalSession.write` records from its I/O thread, the UI reads
/// snapshots on the main thread.
final class CommandHistory: @unchecked Sendable {
    static let shared = CommandHistory()

    private let lock = NSLock()
    private var entries: [String] = []
    private let cap = 300
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cmd_history.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String].self, from: data) { entries = decoded }
    }

    /// Most-recent first.
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return entries }

    func record(_ command: String) {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, cmd.count <= 1000 else { return }
        lock.lock()
        entries.removeAll { $0 == cmd }
        entries.insert(cmd, at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        let snapshot = entries
        lock.unlock()
        try? JSONEncoder().encode(snapshot).write(to: url)
    }

    func clear() {
        lock.lock(); entries = []; lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }
}

/// A picker over the local command history: tap to re-run, or clear.
struct CommandHistoryPicker: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [String] = []
    @State private var query = ""

    private var filtered: [String] {
        query.isEmpty ? items : items.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("No history yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Run a few commands and they'll show up here."))
                } else {
                    List(filtered, id: \.self) { cmd in
                        Button { onPick(cmd); dismiss() } label: {
                            Text(cmd).font(.system(.body, design: .monospaced)).lineLimit(1)
                        }
                    }
                    .searchable(text: $query)
                }
            }
            .navigationTitle("Command history")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if !items.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear", role: .destructive) { CommandHistory.shared.clear(); items = [] }
                    }
                }
            }
            .onAppear { items = CommandHistory.shared.all() }
        }
    }
}
