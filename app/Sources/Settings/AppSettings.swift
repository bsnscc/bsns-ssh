import SwiftUI
import SwiftTerm

/// UserDefaults keys + defaults for app-wide preferences. Views bind with
/// @AppStorage(SettingsKey.x); the terminal layer reads the same keys.
enum SettingsKey {
    static let theme = "terminal.themeId"
    static let fontFamily = "terminal.fontFamily"
    static let fontSize = "terminal.fontSize"
    static let cursorStyle = "terminal.cursorStyle"   // block | bar | underline
    static let cursorBlink = "terminal.cursorBlink"
    static let scrollback = "terminal.scrollback"
    static let keepAwake = "terminal.keepAwake"
    static let bellMode = "terminal.bellMode"          // silent | haptic | sound
    static let optionAsMeta = "input.optionAsMeta"
    static let pinchZoom = "input.pinchZoom"
    static let predictiveText = "input.predictiveText"
    static let showKeyBar = "input.showKeyBar"
    static let tmuxScrollSequence = "input.tmuxScrollSequence"
    static let screenScrollSequence = "input.screenScrollSequence"
    static let multiplexer = "input.multiplexer"           // which copy/scroll buttons to show
    static let keepAliveInterval = "session.keepAliveInterval"
    static let terminalType = "session.terminalType"
    static let appLock = "security.appLock"
    static let commandHistory = "privacy.commandHistory"   // record run commands locally
    static let uploadDir = "transfer.uploadDir"             // remote drop dir for dropped/pasted images
    static let diagnosticsEnabled = "diagnostics.enabled"  // record the on-device event log (off by default)

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            theme: TerminalTheme.bsnsDark.id,
            fontFamily: TerminalFont.families[0],
            fontSize: 15.0,
            cursorStyle: "block",
            cursorBlink: true,
            scrollback: 2000,
            keepAwake: false,
            bellMode: "haptic",
            optionAsMeta: true,
            pinchZoom: true,
            predictiveText: false,
            showKeyBar: true,
            tmuxScrollSequence: "C-b [",
            screenScrollSequence: "C-a [",
            multiplexer: MultiplexerPref.both.rawValue,
            keepAliveInterval: 30,
            terminalType: "xterm-256color",
            appLock: false,
            commandHistory: true,
            uploadDir: "~/.bsns-ssh-drops",
            diagnosticsEnabled: false,
        ])
    }
}

enum KeySequence {
    static func bytes(for spec: String, fallback: [UInt8]) -> [UInt8] {
        let parsed = spec
            .split(whereSeparator: \.isWhitespace)
            .flatMap { parseToken(String($0)) }
        return parsed.isEmpty ? fallback : parsed
    }

    private static func parseToken(_ token: String) -> [UInt8] {
        let lower = token.lowercased()
        if lower == "esc" || lower == "escape" { return [0x1b] }
        if lower == "tab" { return [0x09] }
        if lower == "enter" || lower == "return" { return [0x0d] }
        if lower == "space" { return [0x20] }
        if lower.hasPrefix("0x"), let value = UInt8(lower.dropFirst(2), radix: 16) {
            return [value]
        }
        if let control = controlCharacter(in: token) {
            return [control]
        }
        return Array(token.utf8)
    }

    private static func controlCharacter(in token: String) -> UInt8? {
        let lower = token.lowercased()
        let value: Character?
        if lower.hasPrefix("ctrl-") {
            value = token.dropFirst(5).first
        } else if lower.hasPrefix("control-") {
            value = token.dropFirst(8).first
        } else if lower.hasPrefix("c-") {
            value = token.dropFirst(2).first
        } else if lower.hasPrefix("^") {
            value = token.dropFirst().first
        } else {
            value = nil
        }
        guard let value, let ascii = String(value).uppercased().utf8.first else { return nil }
        return ascii & 0x1f
    }
}

enum CursorShape: String, CaseIterable, Identifiable {
    case block, bar, underline
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    func swiftTerm(blink: Bool) -> CursorStyle {
        switch self {
        case .block: return blink ? .blinkBlock : .steadyBlock
        case .bar: return blink ? .blinkBar : .steadyBar
        case .underline: return blink ? .blinkUnderline : .steadyUnderline
        }
    }
}

enum BellMode: String, CaseIterable, Identifiable {
    case silent, haptic, sound
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Which multiplexer copy/scroll buttons to surface. Most people use one of tmux
/// or GNU screen, so showing both is noise — this lets them pick.
enum MultiplexerPref: String, CaseIterable, Identifiable {
    case both, tmux, screen
    var id: String { rawValue }
    var label: String { self == .both ? "Both" : rawValue }

    /// Resolve to the buttons to show. `tmuxKnown` is true when the app itself
    /// launched the tmux session (mosh + tmux integration), so screen is definitely
    /// wrong and we narrow to tmux regardless of the stored preference — the specific
    /// per-connection fact beats the global default.
    func buttons(tmuxKnown: Bool) -> (tmux: Bool, screen: Bool) {
        if tmuxKnown { return (true, false) }
        switch self {
        case .both:   return (true, true)
        case .tmux:   return (true, false)
        case .screen: return (false, true)
        }
    }
}
