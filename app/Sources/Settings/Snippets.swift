import SwiftUI
import Observation

/// A reusable command (or command sequence). `runOnConnect` snippets are sent
/// automatically into each new session right after it opens.
struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var command: String
    var runOnConnect: Bool = false
}

/// Snippets persisted to a JSON file in Application Support (no secrets).
@MainActor
@Observable
final class SnippetStore {
    private(set) var snippets: [Snippet] = []
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snippets.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = decoded
        }
    }

    func upsert(_ s: Snippet) {
        if let i = snippets.firstIndex(where: { $0.id == s.id }) { snippets[i] = s } else { snippets.append(s) }
        save()
    }
    func remove(_ s: Snippet) { snippets.removeAll { $0.id == s.id }; save() }
    var runOnConnect: [Snippet] { snippets.filter(\.runOnConnect) }

    private func save() { try? JSONEncoder().encode(snippets).write(to: url) }
}

/// Manage snippets: add / edit / delete, and flag which run automatically on connect.
struct SnippetsView: View {
    @Environment(SnippetStore.self) private var store
    @State private var editing: Snippet?

    var body: some View {
        Form {
            Section {
                Text("Reusable commands. Run one from a session's ⌘ menu. \"Run on connect\" "
                     + "snippets are sent automatically when a session opens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(store.snippets) { s in
                    Button { editing = s } label: {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(s.name).foregroundStyle(.primary)
                                if s.runOnConnect {
                                    Text("on connect").font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                                }
                            }
                            Text(s.command.split(separator: "\n").first.map(String.init) ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .onDelete { $0.map { store.snippets[$0] }.forEach(store.remove) }
            }
            Section {
                Button("New snippet") { editing = Snippet(name: "", command: "") }
            }
        }
        .navigationTitle("Snippets")
        .sheet(item: $editing) { snip in SnippetEditor(snippet: snip) { store.upsert($0) } }
    }
}

private struct SnippetEditor: View {
    @State var snippet: Snippet
    let onSave: (Snippet) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("name", text: $snippet.name)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Section("command(s)") {
                    TextField("command", text: $snippet.command, axis: .vertical)
                        .lineLimit(2...6)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                }
                Toggle("Run on connect", isOn: $snippet.runOnConnect)
            }
            .navigationTitle(snippet.name.isEmpty ? "New snippet" : "Edit snippet")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(snippet); dismiss() }
                        .disabled(snippet.name.isEmpty || snippet.command.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// A picker shown over a live session: tap a snippet to send it to the terminal.
struct SnippetPicker: View {
    let onPick: (Snippet) -> Void
    @Environment(SnippetStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.snippets.isEmpty {
                    ContentUnavailableView("No snippets", systemImage: "text.badge.plus",
                                           description: Text("Add snippets in Settings → Snippets."))
                } else {
                    List(store.snippets) { s in
                        Button { onPick(s); dismiss() } label: {
                            VStack(alignment: .leading) {
                                Text(s.name).foregroundStyle(.primary)
                                Text(s.command.split(separator: "\n").first.map(String.init) ?? "")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Run a snippet")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
