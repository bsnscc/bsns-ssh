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
    @AppStorage(SettingsKey.predictiveText) private var predictiveText = false
    @AppStorage(SettingsKey.showKeyBar) private var showKeyBar = true
    @AppStorage(SettingsKey.tmuxScrollSequence) private var tmuxScrollSequence = "C-b ["
    @AppStorage(SettingsKey.screenScrollSequence) private var screenScrollSequence = "C-a ["
    @AppStorage(SettingsKey.multiplexer) private var multiplexer = MultiplexerPref.both.rawValue
    @AppStorage(SettingsKey.keepAliveInterval) private var keepAlive = 30
    @AppStorage(SettingsKey.terminalType) private var terminalType = "xterm-256color"
    @AppStorage(SettingsKey.moshIdleTimeoutHours) private var moshIdleTimeoutHours = 24
    @AppStorage(SettingsKey.appLock) private var appLock = false
    @AppStorage(SettingsKey.commandHistory) private var commandHistory = true
    @AppStorage(SettingsKey.uploadDir) private var uploadDir = "~/.bsns-ssh-drops"
    @AppStorage(SettingsKey.remoteClipboard) private var remoteClipboard = false

    private let scrollbackOptions = [500, 1000, 2000, 5000, 10000]
    private let keepAliveOptions = [15, 30, 60, 120]
    private let termTypes = ["xterm-256color", "xterm", "vt100"]
    private let moshIdleOptions = [0, 1, 4, 12, 24, 72]

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
                Toggle("Show terminal shortcut bar", isOn: $showKeyBar)
                Toggle("Pinch to zoom", isOn: $pinchZoom)
                Toggle("Use Option as Meta", isOn: $optionAsMeta)
                Toggle("Predictive text", isOn: $predictiveText)
            } header: {
                Text("Input")
            } footer: {
                Text("Predictive text can make phone typing easier, but iOS may replace shell commands, paths, flags, or secrets. Smart quotes and dashes stay disabled.")
            }

            Section {
                Picker("Show buttons for", selection: $multiplexer) {
                    ForEach(MultiplexerPref.allCases) { Text($0.label).tag($0.rawValue) }
                }
                TextField("tmux sequence", text: $tmuxScrollSequence)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("screen sequence", text: $screenScrollSequence)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Multiplexer scroll")
            } footer: {
                Text("Which copy/scrollback buttons appear on the terminal. Pick tmux or screen to hide the other; a session the app started as tmux always shows tmux only. The sequences below enter copy mode inside an already-running session — e.g. C-b [, C-a [, C-] [, Esc [. Tokens can be C-x, Ctrl-x, Esc, Tab, Enter, Space, 0x1b, or literal text.")
            }

            Section {
                Picker("Keep-alive", selection: $keepAlive) {
                    ForEach(keepAliveOptions, id: \.self) { Text("\($0) sec").tag($0) }
                }
                Picker("Terminal type", selection: $terminalType) {
                    ForEach(termTypes, id: \.self) { Text($0).tag($0) }
                }
                Picker("Expire idle mosh sessions", selection: $moshIdleTimeoutHours) {
                    ForEach(moshIdleOptions, id: \.self) { hours in
                        Text(hours == 0 ? "Never" : (hours < 24 ? "After \(hours) h" : "After \(hours / 24) d")).tag(hours)
                    }
                }
            } header: {
                Text("Sessions")
            } footer: {
                Text("A mosh session lives on the host and keeps running while you're away — that's what lets it resume. One the app can no longer reach (after a relaunch, or a resume that failed) is asked to quit on your next connect; this is the backstop for the ones that get missed, so they don't pile up holding terminals. With a tmux session set, expiring costs nothing — your work stays in tmux and reconnecting re-attaches it.")
            }

            Section {
                Toggle("Require Face ID / passcode to unlock", isOn: $appLock)
                Toggle("Record command history (on device)", isOn: $commandHistory)
                Toggle("Let the remote copy to this clipboard", isOn: $remoteClipboard)
                NavigationLink { KnownHostsView() } label: { Label("Known Hosts", systemImage: "checkmark.shield") }
            } header: {
                Text("Security")
            } footer: {
                Text("Command history stays on this device and is never synced. Type a command with a leading space to keep that one out of history.\n\nWith remote clipboard on, a command on the server can put text on this device's clipboard (OSC 52) — useful for grabbing a URL or a one-time code without selecting it by hand. Every write shows a banner, and nothing can read your clipboard back.")
            }

            Section {
                TextField("Drop directory", text: $uploadDir)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Image drop")
            } footer: {
                Text("Drag-drop or paste (⌘V) an image onto a terminal to upload it here over SFTP. The absolute remote path is then inserted at the cursor, so you can reference it in a prompt. A leading ~ expands to your home directory on the server.")
            }

            Section("Snippets") {
                NavigationLink { SnippetsView() } label: {
                    Label("Snippets", systemImage: "text.badge.plus")
                }
            }

            Section("Help") {
                NavigationLink { TerminalHelpView() } label: {
                    Label("Terminal Help", systemImage: "questionmark.circle")
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
