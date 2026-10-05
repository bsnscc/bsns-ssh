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
    static func run(store: AgentStore, sessions: SessionStore, agentSocket: AgentSocketController,
                    phoneKeys: PhoneKeyClient, sync: SyncStore, handoff: SessionHandoffStore) async {
        let env = ProcessInfo.processInfo.environment
        // BSNS_DEV_HANDOFF=<folder>, optionally with BSNS_DEV_HANDOFF_PHRASE: use that folder
        // for sync, publish the session named by BSNS_DEV_HANDOFF_PUBLISH
        // ("host|user|tmux", tmux optional) as open here, and report what the
        // other devices in the folder offer. Run with `-handoff.deviceID <id>`
        // to stand in for a second device.
        if let folder = env["BSNS_DEV_HANDOFF"] {
            sync.setFolder(URL(fileURLWithPath: folder))
            // Without a phrase, the one already stored is used.
            if let phrase = env["BSNS_DEV_HANDOFF_PHRASE"] { sync.savePassphrase(phrase) }
            print("dev handoff: stored phrase present=\(sync.hasPassphrase)")
            var open: [RestorableSession] = []
            if let fields = env["BSNS_DEV_HANDOFF_PUBLISH"]?.split(separator: "|", omittingEmptySubsequences: false), fields.count >= 2 {
                open.append(RestorableSession(id: UUID(), title: "\(fields[1])@\(fields[0])", host: String(fields[0]), port: 22,
                                              user: String(fields[1]), useMosh: true, keyBlob: nil,
                                              tmuxSession: fields.count > 2 && !fields[2].isEmpty ? String(fields[2]) : nil))
            }
            // After the app's own launch-time publish (of its real, empty set).
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            handoff.publish(open, sync: sync)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await handoff.refresh(sync: sync)
            print("dev handoff: device \(handoff.deviceID) published \(open.count), offered \(handoff.offers.count)")
            for offer in handoff.offers {
                print("dev handoff: offer [\(offer.continuesWork ? "continue" : "open")] \(SessionHandoffStore.caption(for: offer))")
            }
        }
        // BSNS_DEV_LINK_PAIR=1: pair with the first phone found on the network,
        // accepting the code without asking, and report the keys it offers.
        if env["BSNS_DEV_LINK_PAIR"] == "1" {
            phoneKeys.startBrowsing()
            for _ in 0..<80 where phoneKeys.found.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
            if let phone = phoneKeys.found.first {
                do {
                    let pairing = try await phoneKeys.beginPairing(with: phone)
                    print("dev link: code \(pairing.outcome.code) with \(pairing.outcome.peer.name) (\(pairing.outcome.peer.id))")
                    try await phoneKeys.finish(pairing, accepted: true)
                    let offered = LinkStore.shared.paired.first { $0.id == pairing.outcome.peer.id }?.identities.count ?? 0
                    print("dev link: paired, phone offers \(offered) key(s)")
                } catch {
                    print("dev link: FAILED \(error)")
                }
            } else {
                print("dev link: no phone found")
            }
            phoneKeys.stopBrowsing()
        }
        // BSNS_DEV_AGENT_SOCKET=1 serves the agent socket for this run without
        // touching the saved settings; =all also offers software keys.
        if let mode = env["BSNS_DEV_AGENT_SOCKET"], !mode.isEmpty {
            if let seed = env["BSNS_DEV_KEY"].flatMap({ Data(base64Encoded: $0) }),
               let key = try? FileKey.from(algorithm: .ed25519, privateKeyMaterial: seed, comment: "dev key") {
                await store.agent.add(key)
            }
            agentSocket.pinned = true
            agentSocket.start(enabled: true, hardwareOnly: mode != "all", agent: store.agent, knownHosts: KnownHosts())
            print("dev agent socket: \(agentSocket.state)")
        }
        if env["BSNS_DEV_ENCLAVE"] == "1" {
            do {
                let key = try SecureEnclaveKey.generate(comment: "dev probe")
                print("dev enclave: created \(authorizedKeysLine(key.publicKey).prefix(60))…")
            } catch {
                print("dev enclave: FAILED \(error)")
            }
        }
        // BSNS_DEV_SYNC_ROUNDTRIP=1: encrypt this device's config as sync would,
        // decrypt it again, and report what survived. Nothing is written.
        if env["BSNS_DEV_SYNC_ROUNDTRIP"] == "1" {
            let hosts = HostStore(), known = KnownHostsStore(), snippets = SnippetStore()
            let phrase = "dev-roundtrip-" + UUID().uuidString
            do {
                let sealed = try ConfigService.export(hosts: hosts, knownHosts: known, agent: store, snippets: snippets,
                                                      includeKeys: true, passphrase: phrase)
                let bundle = try ConfigService.decode(sealed, passphrase: phrase)
                let wrong = (try? ConfigService.decode(sealed, passphrase: phrase + "x")) != nil
                let plaintextVisible = String(decoding: sealed, as: UTF8.self).contains("ssh-ed25519")
                print("dev sync: sealed \(sealed.count) bytes, hosts=\(bundle.hosts.count), opens with the wrong phrase=\(wrong), key type visible in the file=\(plaintextVisible)")
            } catch {
                print("dev sync: FAILED \(error)")
            }
        }
        guard env["BSNS_DEV_AUTOCONNECT"] == "1",
              let seed = env["BSNS_DEV_KEY"].flatMap({ Data(base64Encoded: $0) }),
              let host = env["BSNS_DEV_HOST"], let user = env["BSNS_DEV_USER"],
              let key = try? FileKey.from(algorithm: .ed25519, privateKeyMaterial: seed) else { return }
        let port = UInt16(env["BSNS_DEV_PORT"] ?? "22") ?? 22
        await store.agent.add(key)
        // BSNS_DEV_ROUTES: other addresses for BSNS_DEV_HOST, as typed in the form.
        if let routes = env["BSNS_DEV_ROUTES"] {
            RouteBook.shared.set(HostRoutes.parse(routes, excluding: host), for: host)
            let started = Date()
            let route = await Task.detached { SSHShell.reachableRoute(host: host, port: port) }.value
            print("dev routes: \(host) answers via \(route ?? "nothing") after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }
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
                session.attachTmuxIfConfigured(probe)
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
            // BSNS_DEV_FORWARD_URL: forward the server-side port a loopback URL
            // points at, as clicking the link would, and report the local address.
            if let link = env["BSNS_DEV_FORWARD_URL"].flatMap(URL.init(string:)), let loopback = LoopbackURL(link) {
                switch await session.forwardLoopback(loopback) {
                case .success(let url): print("dev forward: \(url.absoluteString)")
                case .failure(let failure): print("dev forward: FAILED \(failure.message)")
                }
            }
        } catch {
            print("dev autoconnect failed: \(error)")
        }
    }
}
#endif
