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
    let tmuxSequence: String
    let screenSequence: String
    /// When a physical keyboard is attached, collapse to the controls that are
    /// still useful on iPad: Escape and multiplexer scroll mode.
    var minimal: Bool = false
    @Binding var muxScrollActive: Bool
    @AppStorage(SettingsKey.multiplexer) private var multiplexer = MultiplexerPref.both.rawValue

    /// tmux/screen buttons to show — narrowed to tmux for app-launched tmux sessions,
    /// else the user's preference. Matches the top control row.
    private var muxButtons: (tmux: Bool, screen: Bool) {
        (MultiplexerPref(rawValue: multiplexer) ?? .both)
            .buttons(tmuxKnown: session.spec.tmuxSession != nil)
    }

    init(session: TerminalSession, handle: TerminalHandle, theme: TerminalTheme,
         tmuxSequence: String = "C-b [", screenSequence: String = "C-a [",
         minimal: Bool = false, muxScrollActive: Binding<Bool> = .constant(false)) {
        self.session = session
        self.handle = handle
        self.theme = theme
        self.tmuxSequence = tmuxSequence
        self.screenSequence = screenSequence
        self.minimal = minimal
        self._muxScrollActive = muxScrollActive
    }

    private enum Key: Hashable {
        case esc, tab
        case tmuxCopy
        case screenCopy
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
            case .tmuxCopy: return "tmux copy mode"
            case .screenCopy: return "screen copy mode"
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

    private var items: [Item] {
        minimal ? minimalItems : fullItems
    }

    /// The tmux/screen (or single "done") copy-mode items, filtered to what applies.
    private var muxItems: [Item] {
        if muxScrollActive { return [Item(label: "done", key: .tmuxCopy, wide: true)] }
        var items: [Item] = []
        if muxButtons.tmux { items.append(Item(label: "tmux", key: .tmuxCopy, wide: true)) }
        if muxButtons.screen { items.append(Item(label: "screen", key: .screenCopy, wide: true)) }
        return items
    }

    private var minimalItems: [Item] {
        [Item(label: "esc", key: .esc, wide: true)] + muxItems
    }

    private var fullItems: [Item] {
        return [
            Item(label: "esc", key: .esc, wide: true),
            Item(label: "tab", key: .tab, wide: true),
        ] + muxItems + [
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
    }

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
        case .esc:
            muxScrollActive = false
            handle.setRemoteScrollMode(false)
            bytes = [0x1b]
        case .tab: bytes = [0x09]
        case .tmuxCopy:
            if muxScrollActive {
                muxScrollActive = false
                handle.setRemoteScrollMode(false)
                bytes = [0x1b]
            } else {
                muxScrollActive = true
                handle.setRemoteScrollMode(true)
                bytes = KeySequence.bytes(for: tmuxSequence, fallback: [0x02, 0x5b])
            }
        case .screenCopy:
            if muxScrollActive {
                muxScrollActive = false
                handle.setRemoteScrollMode(false)
                bytes = [0x1b]
            } else {
                muxScrollActive = true
                handle.setRemoteScrollMode(true)
                bytes = KeySequence.bytes(for: screenSequence, fallback: [0x01, 0x5b])
            }
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
            if muxScrollActive {
                handle.sendRemoteScrollPage(up: up)
                return
            }
            bytes = up ? EscapeSequences.cmdPageUp : EscapeSequences.cmdPageDown
        case .text(let s):
            bytes = Array(s.utf8)
        }
        session.write(bytes[...])
    }
}
