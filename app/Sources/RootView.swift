import SwiftUI
import BsnsSSHCore

struct RootView: View {
    @Environment(AgentStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @State private var homeTab = ProcessInfo.processInfo.environment["BSNS_DEV_TAB"] ?? "connect"

    var body: some View {
        Group {
            if let active = sessions.active {
                NavigationStack {
                    VStack(spacing: 0) {
                        SessionTabBar(activeID: active.id)
                        LiveTerminalScreen(session: active)
                            .id(active.id)
                    }
                }
            } else {
                TabView(selection: $homeTab) {
                    NavigationStack { ConnectView() }
                        .tabItem { Label("Connect", systemImage: "network") }.tag("connect")
                    NavigationStack { KeysView() }
                        .tabItem { Label("Keys", systemImage: "key.fill") }.tag("keys")
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape") }.tag("settings")
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
            // Reconnect via the agent key (now installed), not the bootstrap password.
            let spec = TerminalSession.Spec(host: host, port: port, user: user,
                                            password: nil, agent: store.agent,
                                            knownHosts: known)
            let session = TerminalSession(spec: spec, title: "dev")
            session.adopt(shell)
            sessions.add(session)
            // Dev hook: BSNS_DEV_FORWARD="listenPort:destHost:destPort" exercises
            // local (-L) forwarding headlessly (curl the sim's listen port).
            if let f = env["BSNS_DEV_FORWARD"]?.split(separator: ":"), f.count == 3,
               let lp = UInt16(f[0]), let dp = UInt16(f[2]) {
                let err = shell.addLocalForward(id: UUID(), bindAddress: "127.0.0.1",
                                                listenPort: lp, destHost: String(f[1]), destPort: dp)
                print("dev forward 127.0.0.1:\(lp) -> \(f[1]):\(dp): \(err ?? "ok")")
            }
        } catch {
            print("dev autoconnect failed: \(error)")
        }
    }
}

/// A horizontal strip of one tab per live session, with a trailing button to
/// start a new connection. Tapping a tab switches to it; the ✕ closes it.
struct SessionTabBar: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(TerminalSurfaceCache.self) private var surfaces
    let activeID: TerminalSession.ID

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sessions.sessions) { s in tab(s) }
                Button { sessions.goHome() } label: {
                    Image(systemName: "plus")
                        .font(.callout.weight(.medium))
                        .frame(width: 30, height: 30)
                        .background(Color.secondary.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tab(_ s: TerminalSession) -> some View {
        let isActive = s.id == activeID
        return HStack(spacing: 7) {
            statusDot(s)
            Text(s.title)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
            Button {
                surfaces.drop(s.id); sessions.close(s)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12).padding(.trailing, 9).padding(.vertical, 7)
        .background(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(isActive ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        .frame(maxWidth: 200)
        .contentShape(Capsule())
        .onTapGesture { sessions.activate(s) }
    }

    @ViewBuilder private func statusDot(_ s: TerminalSession) -> some View {
        switch s.status {
        case .connected: Circle().fill(.green).frame(width: 7, height: 7)
        case .connecting: ProgressView().controlSize(.mini)
        case .disconnected: Circle().fill(.orange).frame(width: 7, height: 7)
        }
    }
}
