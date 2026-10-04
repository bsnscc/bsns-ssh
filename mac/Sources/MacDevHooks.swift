#if DEBUG
import Foundation
import BsnsSSHCore

/// Headless integration hooks, driven by environment variables and compiled
/// into debug builds only — the same idea as the iOS app's.
///
/// BSNS_DEV_AUTOCONNECT=1 with BSNS_DEV_KEY (base64 Ed25519 seed), _HOST, _PORT,
/// _USER connects straight to a session, trusting the host key it is shown.
/// BSNS_DEV_MOSH=1 uses mosh; BSNS_DEV_RUN types a command once connected.
/// The key lives in the agent for that run only and is never written to the
/// keychain. BSNS_DEV_ENCLAVE=1 creates (and discards) a Secure Enclave key to
/// show that this Mac and this build can.
@MainActor
enum MacDevHooks {
    static func run(store: AgentStore, sessions: SessionStore) async {
        let env = ProcessInfo.processInfo.environment
        if env["BSNS_DEV_ENCLAVE"] == "1" {
            do {
                let key = try SecureEnclaveKey.generate(comment: "dev probe")
                print("dev enclave: created \(authorizedKeysLine(key.publicKey).prefix(60))…")
            } catch {
                print("dev enclave: FAILED \(error)")
            }
        }
        guard env["BSNS_DEV_AUTOCONNECT"] == "1",
              let seed = env["BSNS_DEV_KEY"].flatMap({ Data(base64Encoded: $0) }),
              let host = env["BSNS_DEV_HOST"], let user = env["BSNS_DEV_USER"],
              let key = try? FileKey.from(algorithm: .ed25519, privateKeyMaterial: seed) else { return }
        let port = UInt16(env["BSNS_DEV_PORT"] ?? "22") ?? 22
        await store.agent.add(key)
        var known = KnownHosts()
        let useMosh = env["BSNS_DEV_MOSH"] == "1"
        do {
            // A first connection only to learn the host key, which the hook trusts.
            let probe = SSHShell()
            do {
                try await probe.connect(host: host, port: port, user: user, agent: store.agent, knownHosts: known)
            } catch SSHShellError.unknownHostKey(let hostKey) {
                known.trust(host: host, port: port, key: hostKey)
                if !useMosh {
                    try await probe.connect(host: host, port: port, user: user, agent: store.agent, knownHosts: known)
                }
            }
            let spec = TerminalSession.Spec(host: host, port: port, user: user, agent: store.agent,
                                            knownHosts: known, useMosh: useMosh, tmuxSession: env["BSNS_DEV_TMUX"])
            let session = TerminalSession(spec: spec, title: useMosh ? "dev · mosh" : "dev")
            if useMosh {
                probe.disconnect()
                sessions.add(session)
                session.start()
            } else {
                session.adopt(probe)
                sessions.add(session)
            }
            for _ in 0..<150 where session.status != .connected {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            print("dev autoconnect: status=\(session.status)")
            if let command = env["BSNS_DEV_RUN"], !command.isEmpty {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                session.runCommand(command)
            }
        } catch {
            print("dev autoconnect failed: \(error)")
        }
    }
}
#endif
