import SwiftUI
import AppKit

struct MacSettingsView: View {
    @Environment(AgentStore.self) private var store
    @Environment(KnownHostsStore.self) private var knownHosts
    @Environment(AgentSocketController.self) private var agentSocket
    @Environment(HostStore.self) private var hosts
    @Environment(SyncStore.self) private var sync
    @Environment(SessionHandoffStore.self) private var handoff
    @Environment(SnippetStore.self) private var snippets
    @State private var syncPassphrase = ""
    @State private var syncing = false
    @AppStorage(AgentSocketController.enabledKey) private var socketEnabled = false
    @AppStorage(AgentSocketController.hardwareOnlyKey) private var socketHardwareOnly = true
    @AppStorage(AgentSocketController.automationKey) private var socketAutomationKeys = false
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
                Toggle("Also offer automation keys", isOn: $socketAutomationKeys)
                    .disabled(!socketEnabled)
                    .help("Automation keys sign without asking, only for the hosts each one lists")
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
            .onChange(of: socketAutomationKeys) { _, _ in applyAgentSocket() }

            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text(sync.folderName ?? "Not set").foregroundStyle(sync.folderName == nil ? .secondary : .primary)
                        Button("Choose…") { chooseSyncFolder() }
                    }
                }
                HStack {
                    SecureField("Passphrase", text: $syncPassphrase,
                                prompt: Text(sync.hasPassphrase ? "Saved — type to change" : "Required"))
                    Button("Save") {
                        sync.savePassphrase(syncPassphrase)
                        syncPassphrase = ""
                    }
                    .disabled(syncPassphrase.isEmpty)
                }
                Toggle("Show open sessions on my other devices", isOn: Binding(
                    get: { handoff.enabled },
                    set: { handoff.enabled = $0 }))
                    .disabled(!sync.autoEnabled)
                HStack {
                    Button("Sync Now") { syncNow() }.disabled(!sync.autoEnabled || syncing)
                    if syncing { ProgressView().controlSize(.small) }
                    if let status = sync.lastStatus { Text(status).font(.callout).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Hosts, known hosts, snippets, settings and software keys are kept in one encrypted file in a folder you choose — iCloud Drive, a shared drive, anything that syncs — and merged on every device that uses the same folder and passphrase. The file is encrypted before it is written, so the storage only ever sees ciphertext. Secure Enclave keys never leave this Mac. Once set, it pulls on launch and pushes when you switch away.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }

    private var socketPath: String {
        AgentSocketServer.socketURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { sync.setFolder(url) }
    }

    private func syncNow() {
        syncing = true
        Task {
            await ConfigSync.autoPull(sync: sync, hosts: hosts, knownHosts: knownHosts, agent: store, snippets: snippets)
            ConfigSync.autoPush(sync: sync, hosts: hosts, knownHosts: knownHosts, agent: store, snippets: snippets)
            sync.lastStatus = "Synced \(Date().formatted(date: .omitted, time: .shortened))"
            syncing = false
        }
    }

    private func applyAgentSocket() {
        agentSocket.apply(agent: store.agent, knownHosts: knownHosts.knownHosts)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
