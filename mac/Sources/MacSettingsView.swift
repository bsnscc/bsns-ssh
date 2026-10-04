import SwiftUI

struct MacSettingsView: View {
    @AppStorage(SettingsKey.theme) private var themeId = TerminalTheme.bsnsDark.id
    @AppStorage(SettingsKey.fontFamily) private var fontFamily = TerminalFont.families[0]
    @AppStorage(SettingsKey.fontSize) private var fontSize = 13.0
    @AppStorage(SettingsKey.scrollback) private var scrollback = 2000
    @AppStorage(SettingsKey.bellMode) private var bellMode = "sound"
    @AppStorage(SettingsKey.remoteClipboard) private var remoteClipboard = false
    @AppStorage(SettingsKey.moshIdleTimeoutHours) private var moshIdleTimeoutHours = 24

    var body: some View {
        Form {
            Section("Terminal") {
                Picker("Theme", selection: $themeId) {
                    ForEach(TerminalTheme.all) { Text($0.id).tag($0.id) }
                }
                Picker("Font", selection: $fontFamily) {
                    ForEach(TerminalFont.families, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Font size: \(Int(fontSize))", value: $fontSize, in: 8...30)
                Picker("Scrollback", selection: $scrollback) {
                    ForEach([500, 1000, 2000, 5000, 10000], id: \.self) { Text("\($0) lines").tag($0) }
                }
                Picker("Bell", selection: $bellMode) {
                    Text("Silent").tag("silent")
                    Text("Sound").tag("sound")
                }
            }
            Section {
                Toggle("Let the remote copy to the clipboard", isOn: $remoteClipboard)
                Picker("Expire idle mosh sessions", selection: $moshIdleTimeoutHours) {
                    ForEach([0, 1, 4, 12, 24, 72], id: \.self) { hours in
                        Text(hours == 0 ? "Never" : (hours < 24 ? "After \(hours) h" : "After \(hours / 24) d")).tag(hours)
                    }
                }
            } header: {
                Text("Sessions")
            } footer: {
                Text("With remote clipboard on, a command on the server can put text on this Mac's clipboard (OSC 52). Nothing can read your clipboard back. Scrollback applies to sessions opened after the change.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.vertical, 8)
    }
}
