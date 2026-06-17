import SwiftUI
import SwiftTerm

/// An always-visible row of the special keys a terminal needs but a touch
/// keyboard lacks: Esc, Tab, Ctrl chords, arrows, paging, and shell symbols.
/// Sends bytes straight to the shell, so it works with a hardware keyboard
/// attached (iPad) where the soft-keyboard accessory never appears. On iPhone
/// it hides while the soft keyboard is up, leaving SwiftTerm's own accessory.
struct TerminalKeyBar: View {
    let session: TerminalSession
    let handle: TerminalHandle
    let theme: TerminalTheme
    /// When a physical keyboard is attached, collapse to just Esc — the one key
    /// most iPad keyboards lack. The rest (Ctrl, Tab, arrows, …) are on the keyboard.
    var minimal: Bool = false

    private enum Key: Hashable {
        case esc, tab
        case ctrl(Character)      // a Ctrl-<letter> chord
        case arrow(Arrow)
        case page(Bool)           // true = up
        case text(String)         // literal symbol

        enum Arrow { case up, down, left, right }
    }

    private struct Item: Identifiable {
        let id = UUID()
        let label: String
        let key: Key
        let wide: Bool

        /// A spoken label for VoiceOver — the visible glyphs (↑ ⇞ …) read poorly,
        /// so name the keys. Falls back to the visible label for plain symbols.
        var accessibilityLabel: String {
            switch key {
            case .esc: return "Escape"
            case .tab: return "Tab"
            case .ctrl(let c): return "Control \(c.uppercased())"
            case .arrow(let a):
                switch a {
                case .up: return "Up arrow"
                case .down: return "Down arrow"
                case .left: return "Left arrow"
                case .right: return "Right arrow"
                }
            case .page(let up): return up ? "Page up" : "Page down"
            case .text(let s): return s
            }
        }
    }

    private var items: [Item] { minimal ? [Item(label: "esc", key: .esc, wide: true)] : fullItems }

    private let fullItems: [Item] = [
        Item(label: "esc", key: .esc, wide: true),
        Item(label: "tab", key: .tab, wide: true),
        Item(label: "⌃C", key: .ctrl("c"), wide: false),
        Item(label: "⌃D", key: .ctrl("d"), wide: false),
        Item(label: "⌃Z", key: .ctrl("z"), wide: false),
        Item(label: "⌃L", key: .ctrl("l"), wide: false),
        Item(label: "⌃R", key: .ctrl("r"), wide: false),
        Item(label: "←", key: .arrow(.left), wide: false),
        Item(label: "↓", key: .arrow(.down), wide: false),
        Item(label: "↑", key: .arrow(.up), wide: false),
        Item(label: "→", key: .arrow(.right), wide: false),
        Item(label: "⇞", key: .page(true), wide: false),
        Item(label: "⇟", key: .page(false), wide: false),
        Item(label: "|", key: .text("|"), wide: false),
        Item(label: "~", key: .text("~"), wide: false),
        Item(label: "/", key: .text("/"), wide: false),
        Item(label: "-", key: .text("-"), wide: false),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Button { send(item.key) } label: {
                        Text(item.label)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .frame(minWidth: item.wide ? 44 : 32, minHeight: 34)
                            .foregroundStyle(Color(theme.foreground.uiColor))
                            .background(Color(theme.ansi[8].uiColor).opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.accessibilityLabel)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Color(theme.background.uiColor))
    }

    private func send(_ key: Key) {
        let bytes: [UInt8]
        switch key {
        case .esc: bytes = [0x1b]
        case .tab: bytes = [0x09]
        case .ctrl(let c):
            // Ctrl-<letter> masks to the low 5 bits of the uppercase letter.
            let upper = Character(c.uppercased())
            bytes = [UInt8(upper.asciiValue ?? 0) & 0x1f]
        case .arrow(let a):
            let app = handle.terminal?.getTerminal().applicationCursor ?? false
            switch a {
            case .up:    bytes = app ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
            case .down:  bytes = app ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
            case .left:  bytes = app ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
            case .right: bytes = app ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
            }
        case .page(let up):
            bytes = up ? EscapeSequences.cmdPageUp : EscapeSequences.cmdPageDown
        case .text(let s):
            bytes = Array(s.utf8)
        }
        session.write(bytes[...])
    }
}
