import SwiftUI
import BsnsSSHCore

struct RootView: View {
    @Environment(AgentStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    @Environment(HostStore.self) private var hosts
    @Environment(KnownHostsStore.self) private var knownHosts
    @Environment(SyncStore.self) private var sync
    @Environment(SnippetStore.self) private var snippets
    @Environment(\.scenePhase) private var scenePhase
    @State private var homeTab = ProcessInfo.processInfo.environment["BSNS_DEV_TAB"] ?? "connect"

    var body: some View {
        Group {
            if let active = sessions.active {
                // LiveTerminalScreen renders its own control row (tabs + actions), so
                // no separate nav bar / tab row here.
                NavigationStack {
                    LiveTerminalScreen(session: active)
                        .id(active.id)
                }
            } else {
                TabView(selection: $homeTab) {
                    NavigationStack { ConnectView(homeTab: $homeTab) }
                        .tabItem { Label("Connect", systemImage: "network") }.tag("connect")
                    NavigationStack { KeysView() }
                        .tabItem { Label("Keys", systemImage: "key.fill") }.tag("keys")
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape") }.tag("settings")
                }
            }
        }
        .tint(Brand.accent)   // brand accent on every control, link, and selection
        .task { await maybeDevAutoConnect() }
        // Auto-sync: pull + merge the user's folder on launch; push when backgrounded.
        .task { await ConfigSync.autoPull(sync: sync, hosts: hosts, knownHosts: knownHosts, agent: store, snippets: snippets) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                ConfigSync.autoPush(sync: sync, hosts: hosts, knownHosts: knownHosts, agent: store, snippets: snippets)
            }
        }
    }

    /// Headless integration hook: BSNS_DEV_AUTOCONNECT=1 + a base64 Ed25519 key
    /// + host/user in the environment connects straight to a live shell
    /// (auto-trusting the host key). Used to verify the SSH path in the
    /// simulator without UI automation. No effect in normal use.
    private func maybeDevAutoConnect() async {
        #if DEBUG
        // Headless integration hooks (env-triggered) — compiled into DEBUG only, so
        // none of this auto-trust / auto-connect code exists in a release build.
        let env = ProcessInfo.processInfo.environment
        // Dev hook: BSNS_DEV_ENCLAVE=1 generates a Secure Enclave key so its
        // creation, storage, and public-key format can be verified in the sim.
        if env["BSNS_DEV_ENCLAVE"] == "1" {
            try? await store.generateEnclaveKey()   // device-only; no-op in the sim
            return
        }
        // Dev hook: BSNS_DEV_SFTP=1 runs an SFTP round-trip self-test (list,
        // upload, download-and-compare, delete) against the same env as autoconnect.
        if env["BSNS_DEV_SFTP"] == "1",
           let keyB64 = env["BSNS_DEV_KEY"], let material = Data(base64Encoded: keyB64),
           let host = env["BSNS_DEV_HOST"], let user = env["BSNS_DEV_USER"],
           let key = try? FileKey.from(algorithm: .ed25519, privateKeyMaterial: material) {
            let port = UInt16(env["BSNS_DEV_PORT"] ?? "22") ?? 22
            await store.agent.add(key)
            var known = KnownHosts()
            let client = SFTPClient()
            do {
                do {
                    try await client.connect(host: host, port: port, user: user, agent: store.agent, knownHosts: known)
                } catch SSHShellError.unknownHostKey(let hk) {
                    known.trust(host: host, port: port, key: hk)
                    try await client.connect(host: host, port: port, user: user, agent: store.agent, knownHosts: known)
                }
                let listing = try await client.list(".")
                let payload = Data("bsns-sftp-test-\(listing.count)".utf8)
                try await client.upload(payload, to: "bsns-sftp-test.txt")
                let back = try await client.download("bsns-sftp-test.txt")
                // Leave a result file on the server so the outcome is inspectable
                // even when sim stdout isn't captured.
                let result = "roundtrip_ok=\(back == payload) bytes=\(back.count) list_count=\(listing.count)"
                try await client.remove("bsns-sftp-test.txt", isDirectory: false)   // also exercises unlink
                // Streaming round-trip (multi-chunk, via temp files) — verifies the
                // bounded-memory download(toFile:)/upload(fromFile:) path.
                let up = FileManager.default.temporaryDirectory.appendingPathComponent("bsns-up.bin")
                let down = FileManager.default.temporaryDirectory.appendingPathComponent("bsns-down.bin")
                let big = Data((0 ..< 200_000).map { UInt8($0 % 251) })
                try big.write(to: up)
                try await client.upload(fromFile: up, to: "bsns-sftp-stream.bin")
                try await client.download("bsns-sftp-stream.bin", toFile: down)
                let streamOK = (try? Data(contentsOf: down)) == big
                try await client.remove("bsns-sftp-stream.bin", isDirectory: false)
                print("SFTP-DEV \(result) stream_ok=\(streamOK) — PASS")
            } catch {
                print("SFTP-DEV FAIL: \(error)")
            }
            client.disconnect()
            return
        }
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
                                            agent: store.agent, knownHosts: known)
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
        #endif
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
                .accessibilityLabel("New session")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        // Background + divider are owned by the enclosing control row (LiveTerminalScreen).
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
            .accessibilityLabel("Close \(s.title)")
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
        // Amber when connected-but-stale (mosh has lost contact) — not a reassuring green.
        case .connected: Circle().fill(s.isStale ? .yellow : .green).frame(width: 7, height: 7)
        case .connecting: ProgressView().controlSize(.mini)
        case .disconnected: Circle().fill(.orange).frame(width: 7, height: 7)
        }
    }
}
