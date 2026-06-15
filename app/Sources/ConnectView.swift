import SwiftUI
import BsnsSSHCore

struct ConnectView: View {
    @Environment(AgentStore.self) private var store
    @Environment(HostStore.self) private var hostStore
    @Environment(KnownHostsStore.self) private var knownHostsStore

    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var connecting = false
    @State private var error: String?
    @State private var activeShell: SSHShell?
    @State private var showTerminal = false
    @State private var pendingHostKey: HostKey?

    var body: some View {
        Form {
            if !hostStore.hosts.isEmpty {
                Section("Saved") {
                    ForEach(hostStore.hosts) { saved in
                        Button {
                            host = saved.host; port = String(saved.port); user = saved.user
                        } label: {
                            VStack(alignment: .leading) {
                                Text(saved.label.isEmpty ? "\(saved.user)@\(saved.host)" : saved.label)
                                    .foregroundStyle(.primary)
                                Text("\(saved.user)@\(saved.host):\(saved.port)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { hostStore.hosts[$0] }.forEach(hostStore.remove)
                    }
                }
            }

            Section("Server") {
                TextField("host", text: $host)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("port", text: $port).keyboardType(.numberPad)
                TextField("user", text: $user)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            }

            Section("Key") {
                if store.identities.isEmpty {
                    Text("Generate a key on the Keys tab first.").foregroundStyle(.secondary)
                } else {
                    Text("\(store.identities.count) agent key(s) will be offered.").foregroundStyle(.secondary)
                }
            }

            Section {
                Button(connecting ? "Connecting…" : "Connect") { attemptConnect() }
                    .disabled(connecting || host.isEmpty || user.isEmpty || store.identities.isEmpty)
                Button("Save host") { saveHost() }
                    .disabled(host.isEmpty || user.isEmpty)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.callout) }
            }
        }
        .navigationTitle("Connect")
        .navigationDestination(isPresented: $showTerminal) {
            if let activeShell {
                LiveTerminalScreen(shell: activeShell, title: "\(user)@\(host)")
            }
        }
        .alert("Unknown host key", isPresented: Binding(get: { pendingHostKey != nil }, set: { if !$0 { pendingHostKey = nil } })) {
            Button("Trust & connect") { trustAndConnect() }
            Button("Cancel", role: .cancel) { pendingHostKey = nil }
        } message: {
            if let key = pendingHostKey {
                Text("First connection to \(host). Verify the fingerprint:\n\n\(key.keyType)\n\(key.fingerprint)")
            }
        }
    }

    private func saveHost() {
        let p = Int(port) ?? 22
        hostStore.add(SavedHost(label: "", host: host, port: p, user: user))
    }

    private func attemptConnect() {
        guard let portValue = UInt16(port) else { error = "Invalid port."; return }
        error = nil
        connecting = true
        let shell = SSHShell()
        let known = knownHostsStore.knownHosts
        Task {
            do {
                try await shell.connect(host: host, port: portValue, user: user, agent: store.agent, knownHosts: known)
                await MainActor.run { connecting = false; activeShell = shell; showTerminal = true }
            } catch SSHShellError.unknownHostKey(let key) {
                await MainActor.run { connecting = false; pendingHostKey = key }
            } catch SSHShellError.hostKeyMismatch(let stored, let presented) {
                await MainActor.run {
                    connecting = false
                    error = "⚠️ HOST KEY CHANGED — possible interception.\nstored: \(stored)\nnow:    \(presented)"
                }
            } catch {
                await MainActor.run { connecting = false; self.error = "\(error)" }
            }
        }
    }

    private func trustAndConnect() {
        guard let key = pendingHostKey, let portValue = UInt16(port) else { return }
        knownHostsStore.trust(host: host, port: portValue, key: key)
        pendingHostKey = nil
        attemptConnect()
    }
}
