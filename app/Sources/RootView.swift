import SwiftUI
import BsnsSSHCore

struct RootView: View {
    @Environment(AgentStore.self) private var store
    @State private var devShell: SSHShell?

    var body: some View {
        Group {
            if let devShell {
                NavigationStack {
                    LiveTerminalScreen(shell: devShell, title: "dev")
                }
            } else {
                TabView {
                    NavigationStack { KeysView() }
                        .tabItem { Label("Keys", systemImage: "key.fill") }
                    NavigationStack { ConnectView() }
                        .tabItem { Label("Connect", systemImage: "network") }
                    NavigationStack { TerminalScreen() }
                        .tabItem { Label("Demo", systemImage: "terminal.fill") }
                }
            }
        }
        .task { await maybeDevAutoConnect() }
    }

    /// Headless integration hook: BSNS_DEV_AUTOCONNECT=1 + a base64 Ed25519 key
    /// + host/user in the environment connects straight to a live shell
    /// (auto-trusting the host key). Used to verify the SSH path in the
    /// simulator without UI automation. No effect in normal use.
    private func maybeDevAutoConnect() async {
        let env = ProcessInfo.processInfo.environment
        guard env["BSNS_DEV_AUTOCONNECT"] == "1",
              let keyB64 = env["BSNS_DEV_KEY"],
              let material = Data(base64Encoded: keyB64),
              let host = env["BSNS_DEV_HOST"],
              let user = env["BSNS_DEV_USER"],
              let key = try? FileKey.from(algorithm: .ed25519, privateKeyMaterial: material)
        else { return }
        let port = UInt16(env["BSNS_DEV_PORT"] ?? "22") ?? 22
        await store.agent.add(key)
        let shell = SSHShell()
        var known = KnownHosts()
        do {
            // If a password is supplied, exercise ssh-copy-id first (install the
            // key via password), then connect with the now-installed key.
            if let password = env["BSNS_DEV_PASSWORD"], !password.isEmpty {
                let lines = [authorizedKeysLine(key.publicKey)]
                do {
                    try await SSHShell.installPublicKeys(lines, host: host, port: port, user: user, password: password, knownHosts: known)
                } catch SSHShellError.unknownHostKey(let hostKey) {
                    known.trust(host: host, port: port, key: hostKey)
                    try await SSHShell.installPublicKeys(lines, host: host, port: port, user: user, password: password, knownHosts: known)
                }
            }
            do {
                try await shell.connect(host: host, port: port, user: user, agent: store.agent, knownHosts: known)
            } catch SSHShellError.unknownHostKey(let hostKey) {
                known.trust(host: host, port: port, key: hostKey) // dev: auto-trust
                try await shell.connect(host: host, port: port, user: user, agent: store.agent, knownHosts: known)
            }
            devShell = shell
        } catch {
            print("dev autoconnect failed: \(error)")
        }
    }
}
