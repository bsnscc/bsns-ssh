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
    @AppStorage(SettingsKey.keepAliveInterval) private var keepAlive = 30
    @AppStorage(SettingsKey.terminalType) private var terminalType = "xterm-256color"
    @AppStorage(SettingsKey.appLock) private var appLock = false
    @AppStorage(SettingsKey.commandHistory) private var commandHistory = true

    private let scrollbackOptions = [500, 1000, 2000, 5000, 10000]
    private let keepAliveOptions = [15, 30, 60, 120]
    private let termTypes = ["xterm-256color", "xterm", "vt100"]

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

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

            Section("Sessions") {
                Picker("Keep-alive", selection: $keepAlive) {
                    ForEach(keepAliveOptions, id: \.self) { Text("\($0) sec").tag($0) }
                }
                Picker("Terminal type", selection: $terminalType) {
                    ForEach(termTypes, id: \.self) { Text($0).tag($0) }
                }
            }

            Section {
                Toggle("Require Face ID / passcode to unlock", isOn: $appLock)
                Toggle("Record command history (on device)", isOn: $commandHistory)
                NavigationLink { KnownHostsView() } label: { Label("Known Hosts", systemImage: "checkmark.shield") }
            } header: {
                Text("Security")
            } footer: {
                Text("Command history stays on this device and is never synced. Type a command with a leading space to keep that one out of history.")
            }

            Section("Snippets") {
                NavigationLink { SnippetsView() } label: {
                    Label("Snippets", systemImage: "text.badge.plus")
                }
            }

            Section("Backup") {
                NavigationLink { ConfigBackupView() } label: {
                    Label("Import / Export", systemImage: "square.and.arrow.up.on.square")
                }
            }

            Section {
                Label {
                    Text("No accounts. No analytics. No telemetry. No location.")
                } icon: {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Brand.accent)
                }
                .font(.callout)
            } footer: {
                Text("Nothing leaves this device except your SSH connections. Your keys are stored on-device and the hardware-backed ones can never be exported.")
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                NavigationLink { DiagnosticsView() } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            }
        }
        .navigationTitle("Settings")
    }
}
