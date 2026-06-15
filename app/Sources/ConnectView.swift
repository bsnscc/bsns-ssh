import SwiftUI
import BsnsSSHCore

struct ConnectView: View {
    @Environment(AgentStore.self) private var store
    @Environment(HostStore.self) private var hostStore
    @Environment(KnownHostsStore.self) private var knownHostsStore

    private enum PendingAction { case connect, install }

    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var activeSession: TerminalSession?
    @State private var showTerminal = false
    @State private var pendingHostKey: HostKey?
    @State private var pendingAction: PendingAction = .connect

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

            Section("Password (optional)") {
                SecureField("password — for login or installing a key", text: $password)
                    .textContentType(.password)
                Text(password.isEmpty
                     ? "Empty: connect with your agent key (\(store.identities.count) available)."
                     : "Set: connect with the password, or install your key below.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button(busy ? "Working…" : "Connect") { attemptConnect() }
                    .disabled(busy || host.isEmpty || user.isEmpty
                              || (password.isEmpty && store.identities.isEmpty))
                Button("Install my key (ssh-copy-id)") { attemptInstall() }
                    .disabled(busy || host.isEmpty || user.isEmpty || password.isEmpty || store.identities.isEmpty)
                Button("Save host") { saveHost() }
                    .disabled(host.isEmpty || user.isEmpty)
            }

            if let notice {
                Section { Text(notice).foregroundStyle(.green).font(.callout) }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.callout) }
            }
        }
        .navigationTitle("Connect")
        .toolbar {
            if !hostStore.hosts.isEmpty { EditButton() }
        }
        .navigationDestination(isPresented: $showTerminal) {
            if let activeSession {
                LiveTerminalScreen(session: activeSession)
            }
        }
        .alert("Unknown host key", isPresented: Binding(get: { pendingHostKey != nil }, set: { if !$0 { pendingHostKey = nil } })) {
            Button("Trust & continue") { trustAndContinue() }
            Button("Cancel", role: .cancel) { pendingHostKey = nil }
        } message: {
            if let key = pendingHostKey {
                Text("First connection to \(host). Verify the fingerprint:\n\n\(key.keyType)\n\(key.fingerprint)")
            }
        }
    }

    private func saveHost() {
        hostStore.add(SavedHost(label: "", host: host, port: Int(port) ?? 22, user: user))
    }

    private func attemptConnect() {
        guard let portValue = UInt16(port) else { error = "Invalid port."; return }
        error = nil; notice = nil; busy = true
        let shell = SSHShell()
        let known = knownHostsStore.knownHosts
        let pw = password.isEmpty ? nil : password
        Task {
            do {
                try await shell.connect(host: host, port: portValue, user: user, agent: store.agent,
                                        knownHosts: known, password: pw)
                await MainActor.run {
                    busy = false
                    let spec = TerminalSession.Spec(host: host, port: portValue, user: user,
                                                    password: pw, agent: store.agent,
                                                    knownHosts: knownHostsStore.knownHosts)
                    let s = TerminalSession(spec: spec, title: "\(user)@\(host)")
                    s.adopt(shell)
                    activeSession = s
                    showTerminal = true
                }
            } catch let e as SSHShellError {
                await MainActor.run { busy = false; handle(e, action: .connect) }
            } catch {
                await MainActor.run { busy = false; self.error = "\(error)" }
            }
        }
    }

    private func attemptInstall() {
        guard let portValue = UInt16(port) else { error = "Invalid port."; return }
        error = nil; notice = nil; busy = true
        let lines = store.identities.map(authorizedKeysLine)
        let known = knownHostsStore.knownHosts
        let pw = password
        Task {
            do {
                try await SSHShell.installPublicKeys(lines, host: host, port: portValue, user: user,
                                                     password: pw, knownHosts: known)
                await MainActor.run {
                    busy = false
                    notice = "Installed \(lines.count) key(s). Clear the password and tap Connect."
                }
            } catch let e as SSHShellError {
                await MainActor.run { busy = false; handle(e, action: .install) }
            } catch {
                await MainActor.run { busy = false; self.error = "\(error)" }
            }
        }
    }

    private func handle(_ e: SSHShellError, action: PendingAction) {
        switch e {
        case .unknownHostKey(let key):
            pendingHostKey = key
            pendingAction = action
        case .hostKeyMismatch(let stored, let presented):
            error = "⚠️ HOST KEY CHANGED — possible interception.\nstored: \(stored)\nnow:    \(presented)"
        case .authFailed(let m):
            error = "Auth failed: \(m)"
        default:
            error = "\(e)"
        }
    }

    private func trustAndContinue() {
        guard let key = pendingHostKey, let portValue = UInt16(port) else { return }
        knownHostsStore.trust(host: host, port: portValue, key: key)
        pendingHostKey = nil
        switch pendingAction {
        case .connect: attemptConnect()
        case .install: attemptInstall()
        }
    }
}
