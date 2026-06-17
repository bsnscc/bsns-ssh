import SwiftUI
import BsnsSSHCore

/// Install one (or more) public keys onto a host's `~/.ssh/authorized_keys` via
/// password auth (ssh-copy-id), so a specific key — including a Secure Enclave or
/// hardware key — can be authorized on a server.
struct InstallKeyView: View {
    let keyLines: [String]
    let keyLabel: String

    @Environment(KnownHostsStore.self) private var knownHostsStore
    @Environment(HostStore.self) private var hostStore
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var pendingHostKey: HostKey?

    private var canInstall: Bool {
        !host.isEmpty && !user.isEmpty && !password.isEmpty && UInt16(port) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(keyLabel).font(.caption.monospaced()).foregroundStyle(.secondary) }

                if !hostStore.hosts.isEmpty {
                    Section("Saved") {
                        ForEach(hostStore.hosts) { saved in
                            Button {
                                host = saved.host; port = String(saved.port); user = saved.user
                            } label: {
                                Text(saved.label.isEmpty ? "\(saved.user)@\(saved.host)" : saved.label)
                            }
                        }
                    }
                }

                Section("Server") {
                    TextField("host", text: $host).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("port", text: $port).keyboardType(.numberPad)
                    TextField("user", text: $user).autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("password", text: $password).textContentType(.password)
                }

                Section {
                    Button(busy ? "Installing…" : "Install") { install() }.disabled(busy || !canInstall)
                } footer: {
                    Text("Connects once with your password to append the key to the server's authorized_keys. The password is not stored.")
                }

                if let notice { Section { Text(notice).foregroundStyle(.green).font(.callout) } }
                if let error { Section { Text(error).foregroundStyle(.red).font(.callout) } }
            }
            .navigationTitle("Install Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .alert("Verify host key", isPresented: Binding(get: { pendingHostKey != nil }, set: { if !$0 { pendingHostKey = nil } })) {
                Button("Trust") { trustAndInstall() }
                Button("Cancel", role: .cancel) { pendingHostKey = nil; busy = false }
            } message: {
                if let key = pendingHostKey {
                    Text("""
                    First connection to \(user)@\(host):\(port).

                    \(key.keyType)
                    \(key.fingerprint)

                    Only trust this if the fingerprint matches what the server's admin gave you (e.g. `ssh-keygen -lf` on the host). Trusting an unverified key can expose your session to interception.
                    """)
                }
            }
        }
    }

    private func install() {
        guard let portValue = UInt16(port) else { error = "Invalid port."; return }
        error = nil; notice = nil; busy = true
        let known = knownHostsStore.knownHosts
        Task {
            do {
                try await SSHShell.installPublicKeys(keyLines, host: host, port: portValue, user: user,
                                                     password: password, knownHosts: known)
                await MainActor.run { busy = false; password = ""; notice = "Installed on \(user)@\(host)." }
            } catch SSHShellError.unknownHostKey(let key) {
                await MainActor.run { pendingHostKey = key }
            } catch SSHShellError.hostKeyMismatch(let stored, let now) {
                await MainActor.run { busy = false; error = "⚠️ Host key changed.\nstored: \(stored)\nnow:    \(now)" }
            } catch SSHShellError.authFailed(let m) {
                await MainActor.run { busy = false; error = "Auth failed: \(m)" }
            } catch let e {
                await MainActor.run { busy = false; error = "\(e)" }
            }
        }
    }

    private func trustAndInstall() {
        guard let key = pendingHostKey, let portValue = UInt16(port) else { return }
        knownHostsStore.trust(host: host, port: portValue, key: key)
        pendingHostKey = nil
        install()
    }
}
