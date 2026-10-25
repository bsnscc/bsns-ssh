import SwiftUI
import BsnsSSHCore

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
    @AppStorage(SettingsKey.scrollGesture) private var scrollGesture = ScrollGesturePref.automatic.rawValue
    @AppStorage(SettingsKey.keepAliveInterval) private var keepAlive = 30
    @AppStorage(SettingsKey.terminalType) private var terminalType = "xterm-256color"
    @AppStorage(SettingsKey.moshIdleTimeoutHours) private var moshIdleTimeoutHours = 24
    @AppStorage(SettingsKey.appLock) private var appLock = false
    @AppStorage(SettingsKey.commandHistory) private var commandHistory = true
    @AppStorage(SettingsKey.uploadDir) private var uploadDir = "~/.bsns-ssh-drops"
    @AppStorage(SettingsKey.remoteClipboard) private var remoteClipboard = false
    @AppStorage(SettingsKey.tmuxClipboard) private var tmuxClipboard = false
    @AppStorage(SettingsKey.confirmPaste) private var confirmPaste = PasteGuard.Policy.whenRisky.rawValue
    @AppStorage(SettingsKey.promptPattern) private var promptPattern = PromptScan.defaultPattern

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
                NavigationLink { KeyBarSettingsView() } label: { Text("Customize Shortcut Bar") }
                    .disabled(!showKeyBar)
                Picker("Confirm multi-line paste", selection: $confirmPaste) {
                    Text("Never").tag(PasteGuard.Policy.never.rawValue)
                    Text("When lines would run").tag(PasteGuard.Policy.whenRisky.rawValue)
                    Text("Always").tag(PasteGuard.Policy.always.rawValue)
                }
                Toggle("Pinch to zoom", isOn: $pinchZoom)
                Toggle("Use Option as Meta", isOn: $optionAsMeta)
                Toggle("Predictive text", isOn: $predictiveText)
            } header: {
                Text("Input")
            } footer: {
                Text("The shortcut bar holds the keys a touch keyboard lacks — Esc, Tab, sticky Ctrl and Alt, arrows — and stays in place whether the keyboard is up or down. Turn it off to get the keyboard's standard accessory row instead.\n\n\"When lines would run\" confirms a multi-line paste only if the program on the other end would run each line as it arrives; programs that take a paste as one block are not interrupted. Inside tmux or screen the app can't see which kind of program is running, so that setting never asks there — choose Always if you want the check inside a multiplexer too.\n\nPredictive text can make phone typing easier, but iOS may replace shell commands, paths, flags, or secrets. Smart quotes and dashes stay disabled.")
            }

            Section {
                Picker("One-finger scroll", selection: $scrollGesture) {
                    ForEach(ScrollGesturePref.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } header: {
                Text("Scrolling")
            } footer: {
                Text("Automatic: when the remote program has asked for the mouse (tmux with mouse on, most full-screen programs), one finger scrolls that program through its own history; otherwise it scrolls the scrollback saved on this device. Two fingers always scroll this device's scrollback.\n\nIn-app scrollback: one finger scrolls this device's scrollback even then, wherever there is one to scroll.\n\nOver mosh this device receives the screen as it changes, not everything that was printed, so its scrollback misses output that went by faster than the screen updated. The remote's own history is the complete one.")
            }

            Section {
                TextField("Prompt pattern", text: $promptPattern)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if PromptScan(pattern: promptPattern) == nil {
                    Text("Not a valid regular expression.").font(.caption).foregroundStyle(.red)
                }
                Button("Use Default Pattern") { promptPattern = PromptScan.defaultPattern }
                    .disabled(promptPattern == PromptScan.defaultPattern)
            } header: {
                Text("Prompts")
            } footer: {
                Text("A regular expression that matches your shell prompt. The tmux history view uses it to jump between prompts and to copy the last command's output. The default matches the usual user@host … $ shapes. (In the terminal itself, a shell that emits prompt marks needs no pattern — see Terminal Help.)")
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
                Toggle("Require \(Biometry.orPasscode) to unlock", isOn: $appLock)
                Toggle("Record command history (on device)", isOn: $commandHistory)
                Toggle("Let the remote copy to this clipboard", isOn: $remoteClipboard)
                Toggle("Set tmux up for it over mosh", isOn: $tmuxClipboard)
                    .disabled(!remoteClipboard)
                NavigationLink { KnownHostsView() } label: { Label("Known Hosts", systemImage: "checkmark.shield") }
                NavigationLink { PhoneKeyView() } label: { Label("Phone as a Key", systemImage: "iphone.radiowaves.left.and.right") }
            } header: {
                Text("Security")
            } footer: {
                Text("Command history stays on this device and is never synced. Type a command with a leading space to keep that one out of history.\n\nWith remote clipboard on, a command on the server can put text on this device's clipboard (OSC 52) — useful for grabbing a URL or a one-time code without selecting it by hand. Every write shows a banner, and nothing can read your clipboard back. tmux copy mode uses this too. Over mosh, tmux has to be told to name the clipboard or its copies never arrive: with the second switch on, the app adds that one option to the tmux server when it starts a tmux session for you (mosh with a tmux session name). For a tmux you start yourself, add the line from Terminal Help to your tmux configuration.")
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
