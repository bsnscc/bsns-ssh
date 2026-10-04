import SwiftUI
import Observation

/// One key on the terminal's shortcut bar.
struct KeyBarItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        /// Sends `sequence`, written the way the scroll sequences are ("Esc",
        /// "C-b n", a literal symbol…).
        case sequence
        /// Sticky modifiers: tap, then the next key is sent with it held.
        case ctrl, alt
        // Navigation keys, sent in whichever form the remote program has asked
        // for (application or normal cursor keys) — which a fixed sequence can't do.
        case up, down, left, right, pageUp, pageDown, home, end
        /// The multiplexer scroll-mode button(s), as chosen in Settings.
        case scrollMode
        /// Shows or hides the software keyboard.
        case keyboard
    }

    var id = UUID()
    var label: String
    var kind: Kind
    var sequence = ""

    init(_ label: String, _ kind: Kind, sequence: String = "") {
        self.label = label
        self.kind = kind
        self.sequence = sequence
    }

    static func key(_ label: String, _ sequence: String) -> KeyBarItem {
        KeyBarItem(label, .sequence, sequence: sequence)
    }

    /// Holding the key repeats it — what a hardware keyboard does for these.
    var repeats: Bool {
        switch kind {
        case .up, .down, .left, .right, .pageUp, .pageDown: return true
        default: return false
        }
    }

    /// A spoken name for VoiceOver: the glyphs (↑ ⇞ ⌃C) read poorly.
    var accessibilityLabel: String {
        switch kind {
        case .ctrl: return "Control"
        case .alt: return "Alt"
        case .up: return "Up arrow"
        case .down: return "Down arrow"
        case .left: return "Left arrow"
        case .right: return "Right arrow"
        case .pageUp: return "Page up"
        case .pageDown: return "Page down"
        case .home: return "Home"
        case .end: return "End"
        case .scrollMode: return "Multiplexer scroll mode"
        case .keyboard: return "Show or hide keyboard"
        case .sequence:
            switch sequence.lowercased() {
            case "esc", "escape": return "Escape"
            case "tab": return "Tab"
            case "enter", "return": return "Return"
            default: break
            }
            if label.hasPrefix("⌃"), label.count == 2 { return "Control \(label.dropFirst())" }
            return label
        }
    }

    /// The bar a new install starts with.
    /// Ordered so that what fits on a phone without scrolling the bar is what
    /// gets used constantly: Esc, Tab, the two modifiers and the arrows.
    static let defaults: [KeyBarItem] = [
        .key("esc", "Esc"), .key("tab", "Tab"),
        KeyBarItem("ctrl", .ctrl), KeyBarItem("alt", .alt),
        KeyBarItem("←", .left), KeyBarItem("↓", .down), KeyBarItem("↑", .up), KeyBarItem("→", .right),
        KeyBarItem("scroll", .scrollMode),
        .key("⌃C", "C-c"), .key("⌃D", "C-d"),
        KeyBarItem("⇞", .pageUp), KeyBarItem("⇟", .pageDown),
        .key("|", "|"), .key("~", "~"), .key("/", "/"), .key("-", "-"),
        KeyBarItem("⌨", .keyboard),
    ]
}

/// Ready-made keys offered by the editor, grouped the way they're listed there.
enum KeyBarPresets {
    struct Group: Identifiable {
        let name: String
        let items: [KeyBarItem]
        var id: String { name }
    }

    static func groups(tmuxPrefix: String) -> [Group] {
        [
            Group(name: "Keys", items: [
                .key("esc", "Esc"), .key("tab", "Tab"), .key("⏎", "Enter"),
                KeyBarItem("ctrl", .ctrl), KeyBarItem("alt", .alt),
                KeyBarItem("←", .left), KeyBarItem("↓", .down), KeyBarItem("↑", .up), KeyBarItem("→", .right),
                KeyBarItem("⇞", .pageUp), KeyBarItem("⇟", .pageDown),
                KeyBarItem("home", .home), KeyBarItem("end", .end),
                KeyBarItem("scroll", .scrollMode), KeyBarItem("⌨", .keyboard),
            ]),
            Group(name: "Symbols", items: Array("|~/-_\\`'\"$&*=+<>[]{}():;!?#%^@").map { KeyBarItem.key(String($0), String($0)) }),
            Group(name: "Control", items: Array("abcdeklrsuwxz").map {
                KeyBarItem.key("⌃" + String($0).uppercased(), "C-" + String($0))
            }),
            Group(name: "Function", items: [
                .key("F1", "Esc OP"), .key("F2", "Esc OQ"), .key("F3", "Esc OR"), .key("F4", "Esc OS"),
                .key("F5", "Esc [15~"), .key("F6", "Esc [17~"), .key("F7", "Esc [18~"), .key("F8", "Esc [19~"),
                .key("F9", "Esc [20~"), .key("F10", "Esc [21~"), .key("F11", "Esc [23~"), .key("F12", "Esc [24~"),
            ]),
            // Built on the prefix already configured for tmux scroll mode, so a
            // remapped prefix carries over.
            Group(name: "tmux", items: [
                .key("win+", "\(tmuxPrefix) c"), .key("win▶", "\(tmuxPrefix) n"), .key("◀win", "\(tmuxPrefix) p"),
                .key("last", "\(tmuxPrefix) l"), .key("wins", "\(tmuxPrefix) w"), .key("zoom", "\(tmuxPrefix) z"),
                .key("pane", "\(tmuxPrefix) o"), .key("split─", "\(tmuxPrefix) \""), .key("split│", "\(tmuxPrefix) %"),
                .key("detach", "\(tmuxPrefix) d"),
            ]),
        ]
    }

    /// The prefix key from the configured copy-mode sequence ("C-b [" → "C-b").
    static func tmuxPrefix(fromScrollSequence sequence: String) -> String {
        sequence.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "C-b"
    }
}

/// The user's shortcut bar, kept in UserDefaults as JSON. Nothing stored means
/// the default bar, so a future change to the defaults reaches anyone who never
/// customised theirs.
@MainActor
@Observable
final class KeyBarStore {
    static let shared = KeyBarStore()

    private(set) var items: [KeyBarItem]

    private init() {
        if let data = UserDefaults.standard.data(forKey: SettingsKey.keyBar),
           let decoded = try? JSONDecoder().decode([KeyBarItem].self, from: data), !decoded.isEmpty {
            items = decoded
        } else {
            items = KeyBarItem.defaults
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: SettingsKey.keyBar) }
    }

    func add(_ item: KeyBarItem) {
        var copy = item
        copy.id = UUID()   // presets are templates; every added key is its own
        items.append(copy)
        save()
    }

    func update(_ item: KeyBarItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    func reset() {
        items = KeyBarItem.defaults
        UserDefaults.standard.removeObject(forKey: SettingsKey.keyBar)
    }
}

/// Arrange the shortcut bar: reorder, remove, add from the presets, or define a
/// key that sends any sequence.
struct KeyBarSettingsView: View {
    @State private var store = KeyBarStore.shared
    @State private var editing: KeyBarItem?
    @State private var confirmReset = false
    @AppStorage(SettingsKey.tmuxScrollSequence) private var tmuxScrollSequence = "C-b ["

    private var groups: [KeyBarPresets.Group] {
        KeyBarPresets.groups(tmuxPrefix: KeyBarPresets.tmuxPrefix(fromScrollSequence: tmuxScrollSequence))
    }

    var body: some View {
        List {
            Section {
                ForEach(store.items) { item in
                    Button { if item.kind == .sequence { editing = item } } label: {
                        HStack {
                            Text(item.label).font(.body.monospaced()).foregroundStyle(.primary)
                            Spacer()
                            Text(detail(item)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
                .onDelete { store.remove(at: $0) }
            } header: {
                Text("Bar")
            } footer: {
                Text("Drag to reorder, swipe to remove. Tap a key that sends a sequence to change it. Ctrl and Alt are sticky: tap one, then the next key — from the bar or the keyboard — is sent with it held.")
            }

            Section("Add") {
                ForEach(groups) { group in
                    Menu(group.name) {
                        ForEach(group.items) { item in
                            Button(item.label) { store.add(item) }
                        }
                    }
                }
                Button("Custom Key…") { editing = KeyBarItem.key("", "") }
            }

            Section {
                Button("Reset to Defaults", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("Shortcut Bar")
        .toolbar { EditButton() }
        .sheet(item: $editing) { item in
            KeyEditor(item: item) { edited in
                if store.items.contains(where: { $0.id == edited.id }) { store.update(edited) } else { store.add(edited) }
            }
        }
        .confirmationDialog("Replace the bar with the default keys?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { store.reset() }
            Button("Cancel", role: .cancel) { }
        }
    }

    private func detail(_ item: KeyBarItem) -> String {
        switch item.kind {
        case .sequence: return item.sequence
        case .ctrl, .alt: return "sticky"
        case .scrollMode: return "tmux / screen"
        case .keyboard: return "keyboard"
        default: return ""
        }
    }
}

private struct KeyEditor: View {
    @State var item: KeyBarItem
    let onSave: (KeyBarItem) -> Void
    @Environment(\.dismiss) private var dismiss

    private var valid: Bool {
        !item.label.trimmingCharacters(in: .whitespaces).isEmpty
            && !KeySequence.bytes(for: item.sequence, fallback: []).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $item.label)
                    TextField("Sequence — e.g. C-b n", text: $item.sequence)
                        .font(.body.monospaced())
                }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

                Section {
                    Text("Tokens separated by spaces: C-x or Ctrl-x for a control key, Esc, Tab, Enter, Space, 0x1b for a raw byte, anything else as literal text. \"C-b n\" sends the tmux prefix and then n; \"Esc [15~\" is F5.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        item.label = item.label.trimmingCharacters(in: .whitespaces)
                        onSave(item)
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
        }
    }
}
