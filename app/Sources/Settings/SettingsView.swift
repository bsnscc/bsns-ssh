import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.theme) private var themeId = TerminalTheme.bsnsDark.id
    @AppStorage(SettingsKey.fontFamily) private var fontFamily = TerminalFont.families[0]
    @AppStorage(SettingsKey.fontSize) private var fontSize = 15.0
    @AppStorage(SettingsKey.cursorStyle) private var cursorStyle = "block"
    @AppStorage(SettingsKey.cursorBlink) private var cursorBlink = true
    @AppStorage(SettingsKey.scrollback) private var scrollback = 2000
    @AppStorage(SettingsKey.keepAwake) private var keepAwake = false
    @AppStorage(SettingsKey.bellMode) private var bellMode = "haptic"
    @AppStorage(SettingsKey.optionAsMeta) private var optionAsMeta = true
    @AppStorage(SettingsKey.pinchZoom) private var pinchZoom = true
    @AppStorage(SettingsKey.showKeyBar) private var showKeyBar = true

    private let scrollbackOptions = [500, 1000, 2000, 5000, 10000]

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $themeId) {
                    ForEach(TerminalTheme.all) { Text($0.id).tag($0.id) }
                }
                Picker("Font", selection: $fontFamily) {
                    ForEach(TerminalFont.families, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Font size: \(Int(fontSize))", value: $fontSize, in: 8...30)
            }

            Section("Cursor") {
                Picker("Style", selection: $cursorStyle) {
                    ForEach(CursorShape.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Blink", isOn: $cursorBlink)
            }

            Section("Terminal") {
                Picker("Scrollback", selection: $scrollback) {
                    ForEach(scrollbackOptions, id: \.self) { Text("\($0) lines").tag($0) }
                }
                Picker("Bell", selection: $bellMode) {
                    ForEach(BellMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Keep screen awake while connected", isOn: $keepAwake)
            }

            Section {
                Toggle("Show key bar", isOn: $showKeyBar)
                Toggle("Pinch to zoom", isOn: $pinchZoom)
                Toggle("Use Option as Meta", isOn: $optionAsMeta)
            } header: {
                Text("Input")
            } footer: {
                Text("Option as Meta sends Esc-prefixed keys for Alt shortcuts (vim, emacs, readline).")
            }
        }
        .navigationTitle("Settings")
    }
}
