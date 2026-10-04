import SwiftUI
import AppKit

struct MacSettingsView: View {
    @Environment(AgentStore.self) private var store
    @Environment(KnownHostsStore.self) private var knownHosts
    @Environment(AgentSocketController.self) private var agentSocket
    @AppStorage(AgentSocketController.enabledKey) private var socketEnabled = false
    @AppStorage(AgentSocketController.hardwareOnlyKey) private var socketHardwareOnly = true
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
            Section {
                Toggle("Serve keys to other programs", isOn: $socketEnabled)
                Toggle("Only keys that ask every time", isOn: $socketHardwareOnly)
                    .disabled(!socketEnabled)
                if socketEnabled {
                    switch agentSocket.state {
                    case .listening:
                        LabeledContent("Socket") {
                            Text(socketPath).font(.callout.monospaced()).textSelection(.enabled)
                        }
                        HStack {
                            Button("Copy ssh Config") { copy("Host *\n    IdentityAgent \(socketPath)\n") }
                            Button("Copy Shell Export") { copy("export SSH_AUTH_SOCK=\(socketPath)\n") }
                        }
                    case .failed(let message):
                        Text(message).foregroundStyle(.red)
                    case .off:
                        EmptyView()
                    }
                }
            } header: {
                Text("Agent")
            } footer: {
                Text("With this on, ssh, git, scp and rsync in any terminal can sign in with the keys held here — add the ssh config lines to ~/.ssh/config, or export the variable in your shell profile. \"Only keys that ask every time\" offers just the Secure Enclave keys, each use confirmed with Touch ID and a prompt naming the program and the host. Turn it off to offer software keys too; those sign without asking, as they would in any ssh agent. Every use is listed under Keys → Activity.")
            }
            .onChange(of: socketEnabled) { _, _ in applyAgentSocket() }
            .onChange(of: socketHardwareOnly) { _, _ in applyAgentSocket() }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }

    private var socketPath: String {
        AgentSocketServer.socketURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func applyAgentSocket() {
        agentSocket.apply(agent: store.agent, knownHosts: knownHosts.knownHosts)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
