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
    static let showKeyBar = "input.showKeyBar"
    static let keepAliveInterval = "session.keepAliveInterval"
    static let terminalType = "session.terminalType"
    static let appLock = "security.appLock"
    static let commandHistory = "privacy.commandHistory"   // record run commands locally
    static let uploadDir = "transfer.uploadDir"             // remote drop dir for dropped/pasted images

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
            showKeyBar: true,
            keepAliveInterval: 30,
            terminalType: "xterm-256color",
            appLock: false,
            commandHistory: true,
            uploadDir: "~/.bsns-ssh-drops",
        ])
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
