import UIKit
import SwiftTerm

/// A terminal color scheme: background / foreground / cursor + the 16-color
/// ANSI palette. Applied to a SwiftTerm `TerminalView`.
struct TerminalTheme: Identifiable, Hashable {
    let id: String // display name
    let background: RGB
    let foreground: RGB
    let cursor: RGB
    let ansi: [RGB] // 16 entries: 0-7 normal, 8-15 bright

    struct RGB: Hashable {
        let r: UInt8, g: UInt8, b: UInt8
        var uiColor: UIColor {
            UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        var swiftTermColor: Color {
            Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
        }
    }

    func apply(to terminal: TerminalView) {
        terminal.installColors(ansi.map(\.swiftTermColor))
        terminal.nativeBackgroundColor = background.uiColor
        terminal.nativeForegroundColor = foreground.uiColor
        terminal.caretColor = cursor.uiColor
    }

    static let all: [TerminalTheme] = [bsnsDark, solarizedDark, dracula]
    static func named(_ id: String) -> TerminalTheme { all.first { $0.id == id } ?? bsnsDark }

    private static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> RGB { RGB(r: r, g: g, b: b) }

    static let bsnsDark = TerminalTheme(
        id: "bsns Dark",
        background: rgb(13, 17, 23), foreground: rgb(199, 204, 209), cursor: rgb(74, 222, 128),
        ansi: [
            rgb(30, 34, 42), rgb(224, 108, 117), rgb(152, 195, 121), rgb(229, 192, 123),
            rgb(97, 175, 239), rgb(198, 120, 221), rgb(86, 182, 194), rgb(171, 178, 191),
            rgb(92, 99, 112), rgb(224, 108, 117), rgb(152, 195, 121), rgb(229, 192, 123),
            rgb(97, 175, 239), rgb(198, 120, 221), rgb(86, 182, 194), rgb(255, 255, 255),
        ])

    static let solarizedDark = TerminalTheme(
        id: "Solarized Dark",
        background: rgb(0, 43, 54), foreground: rgb(131, 148, 150), cursor: rgb(147, 161, 161),
        ansi: [
            rgb(7, 54, 66), rgb(220, 50, 47), rgb(133, 153, 0), rgb(181, 137, 0),
            rgb(38, 139, 210), rgb(211, 54, 130), rgb(42, 161, 152), rgb(238, 232, 213),
            rgb(0, 43, 54), rgb(203, 75, 22), rgb(88, 110, 117), rgb(101, 123, 131),
            rgb(131, 148, 150), rgb(108, 113, 196), rgb(147, 161, 161), rgb(253, 246, 227),
        ])

    static let dracula = TerminalTheme(
        id: "Dracula",
        background: rgb(40, 42, 54), foreground: rgb(248, 248, 242), cursor: rgb(248, 248, 242),
        ansi: [
            rgb(33, 34, 44), rgb(255, 85, 85), rgb(80, 250, 123), rgb(241, 250, 140),
            rgb(189, 147, 249), rgb(255, 121, 198), rgb(139, 233, 253), rgb(248, 248, 242),
            rgb(98, 114, 164), rgb(255, 110, 103), rgb(90, 247, 142), rgb(244, 249, 157),
            rgb(202, 169, 250), rgb(255, 146, 208), rgb(154, 237, 254), rgb(255, 255, 255),
        ])
}

/// Available monospace font families.
enum TerminalFont {
    static let families = ["SF Mono", "Menlo", "Courier New"]

    static func font(family: String, size: CGFloat) -> UIFont {
        if family == "SF Mono" {
            return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return UIFont(name: family, size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
