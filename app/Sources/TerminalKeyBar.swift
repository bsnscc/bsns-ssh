import SwiftUI
import SwiftTerm

/// The row of keys a terminal needs but a touch keyboard lacks: Esc, Tab,
/// sticky Ctrl and Alt, arrows, paging, shell symbols — whatever the user has
/// put on it (see `KeyBarStore`). It sits above the software keyboard when
/// that is up and along the bottom when it is down, so the same keys are in
/// the same place either way, and it works with a hardware keyboard attached
/// (where a keyboard accessory never appears).
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
    @State private var store = KeyBarStore.shared
    // Mirrors of the terminal view's sticky modifiers, for the highlight. The
    // view clears its own flag once the modifier has been applied to a key and
    // announces it; that announcement clears these.
    @State private var ctrlArmed = false
    @State private var altArmed = false

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

    /// One button on screen. A bar item is usually one button; the scroll-mode
    /// item expands to a button per multiplexer (or a single "done").
    private struct Button_: Identifiable {
        enum Action { case item(KeyBarItem), tmuxScroll, screenScroll }
        let id: String
        let label: String
        let action: Action
        var accessibilityLabel: String
        var repeats = false
    }

    private var scrollButtons: [Button_] {
        if muxScrollActive {
            return [Button_(id: "scroll-done", label: "done", action: .tmuxScroll,
                            accessibilityLabel: "Exit multiplexer scroll mode")]
        }
        var buttons: [Button_] = []
        if muxButtons.tmux {
            buttons.append(Button_(id: "scroll-tmux", label: "tmux", action: .tmuxScroll, accessibilityLabel: "tmux copy mode"))
        }
        if muxButtons.screen {
            buttons.append(Button_(id: "scroll-screen", label: "screen", action: .screenScroll, accessibilityLabel: "screen copy mode"))
        }
        return buttons
    }

    private var buttons: [Button_] {
        if minimal {
            let esc = KeyBarItem.key("esc", "Esc")
            return [Button_(id: "esc", label: esc.label, action: .item(esc), accessibilityLabel: "Escape")] + scrollButtons
        }
        return store.items.flatMap { item -> [Button_] in
            if item.kind == .scrollMode { return scrollButtons }
            return [Button_(id: item.id.uuidString, label: item.label, action: .item(item),
                            accessibilityLabel: item.accessibilityLabel, repeats: item.repeats)]
        }
    }

    private func isArmed(_ button: Button_) -> Bool {
        guard case .item(let item) = button.action else { return false }
        return (item.kind == .ctrl && ctrlArmed) || (item.kind == .alt && altArmed)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(buttons) { button in
                    let armed = isArmed(button)
                    Button { perform(button.action) } label: {
                        Text(button.label)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 4)
                            .frame(minWidth: button.label.count > 1 ? 44 : 32, minHeight: 34)
                            .foregroundStyle(armed ? Color(theme.background.uiColor) : Color(theme.foreground.uiColor))
                            .background(armed ? Brand.accent : Color(theme.ansi[8].uiColor).opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .buttonRepeatBehavior(button.repeats ? .enabled : .disabled)
                    .accessibilityLabel(button.accessibilityLabel)
                    .accessibilityAddTraits(armed ? .isSelected : [])
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Color(theme.background.uiColor))
        .onReceive(NotificationCenter.default.publisher(for: .terminalViewControlModifierReset)) { note in
            if (note.object as AnyObject?) === handle.terminal { ctrlArmed = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalViewMetaModifierReset)) { note in
            if (note.object as AnyObject?) === handle.terminal { altArmed = false }
        }
    }

    private func perform(_ action: Button_.Action) {
        switch action {
        case .tmuxScroll: toggleScrollMode(sequence: tmuxSequence, fallback: [0x02, 0x5b])
        case .screenScroll: toggleScrollMode(sequence: screenSequence, fallback: [0x01, 0x5b])
        case .item(let item): press(item)
        }
    }

    private func toggleScrollMode(sequence: String, fallback: [UInt8]) {
        if muxScrollActive {
            muxScrollActive = false
            handle.setRemoteScrollMode(false)
            session.write([UInt8(0x1b)][...])
        } else {
            muxScrollActive = true
            handle.setRemoteScrollMode(true)
            session.write(KeySequence.bytes(for: sequence, fallback: fallback)[...])
        }
    }

    private func press(_ item: KeyBarItem) {
        guard let terminal = handle.terminal else { return }
        let app = terminal.getTerminal().applicationCursor
        var bytes: [UInt8]
        switch item.kind {
        case .ctrl:
            ctrlArmed.toggle()
            terminal.controlModifier = ctrlArmed
            return
        case .alt:
            altArmed.toggle()
            terminal.metaModifier = altArmed
            return
        case .keyboard:
            if terminal.isFirstResponder { _ = terminal.resignFirstResponder() } else { _ = terminal.becomeFirstResponder() }
            return
        case .scrollMode:
            return   // expanded into its own buttons above
        case .up:    bytes = app ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
        case .down:  bytes = app ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
        case .left:  bytes = app ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
        case .right: bytes = app ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
        case .home:  bytes = app ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal
        case .end:   bytes = app ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal
        case .pageUp, .pageDown:
            if muxScrollActive {
                handle.sendRemoteScrollPage(up: item.kind == .pageUp)
                return
            }
            bytes = item.kind == .pageUp ? EscapeSequences.cmdPageUp : EscapeSequences.cmdPageDown
        case .sequence:
            bytes = KeySequence.bytes(for: item.sequence, fallback: [])
            guard !bytes.isEmpty else { return }
            if bytes == [0x1b], muxScrollActive {
                // Esc leaves copy mode on the remote; leave it here too.
                muxScrollActive = false
                handle.setRemoteScrollMode(false)
            }
            // A sticky modifier applies to a bar key the way it would to a typed
            // one: Ctrl folds a single character to its control code, Alt
            // prefixes Escape.
            if ctrlArmed, bytes.count == 1, (0x40...0x7e).contains(bytes[0]) { bytes = [bytes[0] & 0x1f] }
            if altArmed { bytes = [0x1b] + bytes }
        }
        // Whatever was sent, an armed modifier has now been used (or passed over).
        if ctrlArmed { terminal.controlModifier = false; ctrlArmed = false }
        if altArmed { terminal.metaModifier = false; altArmed = false }
        session.write(bytes[...])
    }
}
