#if DEBUG
import Foundation
import AppKit
import CloudKit
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
                    phoneKeys: PhoneKeyClient, sync: SyncStore, handoff: SessionHandoffStore,
                    surfaces: MacSurfaceCache, machines: MachineBoard) async {
        let env = ProcessInfo.processInfo.environment
        // BSNS_DEV_MACHINES=1 with BSNS_DEV_KEY/_HOST/_PORT/_USER: watch that
        // host (not saved anywhere) beside this Mac and report what the board
        // sees for half a minute.
        if env["BSNS_DEV_MACHINES"] == "1",
           let seed = env["BSNS_DEV_KEY"].flatMap({ Data(base64Encoded: $0) }),
           let host = env["BSNS_DEV_HOST"], let user = env["BSNS_DEV_USER"],
           let key = try? FileKey.from(algorithm: .ed25519, privateKeyMaterial: seed) {
            let port = UInt16(env["BSNS_DEV_PORT"] ?? "22") ?? 22
            await store.agent.add(key)
            var known = KnownHosts()
            let probe = SSHShell()
            do {
                try await probe.connect(host: host, port: port, user: user, agent: store.agent, knownHosts: known)
            } catch SSHShellError.unknownHostKey(let hostKey) {
                known.trust(host: host, port: port, key: hostKey)
            } catch {}
            probe.disconnect()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let saved = SavedHost(label: "test machine", host: host, port: Int(port), user: user)
            machines.sync(hosts: [saved], localName: "This Mac")
            machines.onAttention = { machine, window in print("dev machines: ATTENTION \(machine.name) \(window.id) (\(window.command))") }
            machines.watchLocal()
            machines.watch(saved.id.uuidString, agent: store.agent, knownHosts: known, keyBlob: nil)
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                for machine in machines.machines {
                    let rows = machine.isLocal ? "\(machine.overview?.windows.count ?? -1) windows"
                        : (machine.overview?.windows.map { "\($0.id)=\(machine.attention(for: $0))" }.joined(separator: " ") ?? "-")
                    print("dev machines: \(machine.name) \(machine.state) load=\(machine.overview?.load.first ?? -1) | \(rows)")
                }
            }
            if let target = machines.machines.last, let window = target.overview?.windows.last {
                await machines.selectWindow(machine: target.id, session: window.session, index: 0)
                machines.acknowledge(machine: target.id, window: window.id)
                print("dev machines: after a look, waiting=\(machines.waitingCount)")
            }
            return
        }
        // BSNS_DEV_SNAPSHOT=<file.png>: a few seconds in (BSNS_DEV_SNAPSHOT_AFTER,
        // default 6), save a picture of the app's main window as the app drew it.
        if let path = env["BSNS_DEV_SNAPSHOT"] {
            let delay = Double(env["BSNS_DEV_SNAPSHOT_AFTER"] ?? "") ?? 6
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                      let frameView = window.contentView?.superview,
                      let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
                    print("dev snapshot: no window")
                    return
                }
                if let size = env["BSNS_DEV_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                    window.setContentSize(NSSize(width: size[0], height: size[1]))
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("dev snapshot: saved \(Int(frameView.bounds.width))x\(Int(frameView.bounds.height))")
            }
        }
        // BSNS_DEV_ASK_ANSWER=<choice>: stand in for the person — two seconds
        // after a question appears, answer it with that choice (questions whose
        // text contains "nobody" or "goes away" are left alone), and report
        // what the inbox sees.
        // BSNS_DEV_RELAY_SELF=1: prove the iCloud path on this Mac alone, by
        // pairing it with a second identity made up for the test — which stands
        // in for the phone, reads the ask from iCloud and writes the answer.
        if env["BSNS_DEV_RELAY_SELF"] == "1" {
            await DevRelayLoop.run()
            return
        }
        if let choice = env["BSNS_DEV_ASK_ANSWER"] {
            Task { @MainActor in
                var seen: Set<UUID> = []
                var lastCount = -1
                while true {
                    let center = AskCenter.shared
                    if center.pending.count != lastCount {
                        lastCount = center.pending.count
                        print("dev ask: pending=\(lastCount) history=\(center.history.count) \(center.pending.map { "[\($0.source ?? "?")] \($0.text) \($0.options)" }.joined(separator: "; "))")
                    }
                    for ask in center.pending where !seen.contains(ask.id) && Date().timeIntervalSince(ask.created) >= 2 {
                        seen.insert(ask.id)
                        if ask.text.contains("nobody") || ask.text.contains("goes away") { continue }
                        let accepted = center.answer(AskAnswer(askID: ask.id, choice: choice))
                        let forged = center.answer(AskAnswer(askID: ask.id, choice: "something else"))
                        print("dev ask: answered '\(choice)' accepted=\(accepted); a second, unoffered answer accepted=\(forged)")
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        // BSNS_DEV_CLOUD_PROBE=1: can this build reach the user's private iCloud
        // database at all? Saves one throwaway record, reads it back, deletes it.
        if env["BSNS_DEV_CLOUD_PROBE"] == "1" {
            let container = CKContainer(identifier: "iCloud.cc.bsns.ssh")
            do {
                let status = try await container.accountStatus()
                print("dev cloud: account status=\(status.rawValue) (1 = available)")
                let database = container.privateCloudDatabase
                let id = CKRecord.ID(recordName: "probe-\(UUID().uuidString)")
                let record = CKRecord(recordType: "Relay", recordID: id)
                record["kind"] = 9 as NSNumber
                record["box"] = Data("probe".utf8) as NSData
                record["to"] = "probe" as NSString
                let saved = try await database.save(record)
                let fetched = try await database.record(for: saved.recordID)
                print("dev cloud: round trip ok, box=\((fetched["box"] as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "?")")
                _ = try await database.deleteRecord(withID: saved.recordID)
                print("dev cloud: probe record deleted")
            } catch {
                print("dev cloud: FAILED \(error)")
            }
            return
        }
        // BSNS_DEV_WORKSPACE="name|path|status command": add that workspace (the
        // test removes workspaces.json afterwards).
        if let fields = env["BSNS_DEV_WORKSPACE"]?.split(separator: "|", omittingEmptySubsequences: false), fields.count >= 2 {
            WorkspaceStore.shared.upsert(Workspace(name: String(fields[0]), path: String(fields[1]),
                                                   statusCommand: fields.count > 2 ? String(fields[2]) : nil))
        }
        // BSNS_DEV_LOCAL=1: open a local shell, type BSNS_DEV_RUN into it, and
        // report whether its tab is still there a few seconds later.
        if env["BSNS_DEV_LOCAL"] == "1" {
            // BSNS_DEV_LOCAL_COMMAND: the tab runs this instead of a shell.
            let session = LocalShellLauncher.open(sessions: sessions, surfaces: surfaces, store: store,
                                                  command: env["BSNS_DEV_LOCAL_COMMAND"],
                                                  title: env["BSNS_DEV_LOCAL_COMMAND"].map { _ in "dev command" })
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            print("dev local: \(session.title) status=\(session.status)")
            if let command = env["BSNS_DEV_RUN"], !command.isEmpty { session.runCommand(command) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            print("dev local: tabs open now=\(sessions.sessions.count)")
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            print("dev local: later, tabs open=\(sessions.sessions.count)")
            return
        }
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
        // BSNS_DEV_LINK_PURGE=1: forget every paired phone and this Mac's link
        // identity (test cleanup).
        if env["BSNS_DEV_LINK_PURGE"] == "1" {
            for device in LinkStore.shared.paired { await phoneKeys.unpair(device.id) }
            let status = SecItemDelete(Keychain.scoped([kSecClass as String: kSecClassGenericPassword,
                                                        kSecAttrService as String: "cc.bsns.ssh.link"]) as CFDictionary)
            print("dev link: purged, paired=\(LinkStore.shared.paired.count) identity delete status=\(status)")
            return
        }
        if env["BSNS_DEV_LINK_PAIR"] == "1" {
            // BSNS_DEV_LINK_ADDRESS: reach the phone by address, not discovery.
            let byAddress = env["BSNS_DEV_LINK_ADDRESS"].map { PhoneKeyClient.Found.at($0) }
            if byAddress == nil {
                phoneKeys.startBrowsing()
                for _ in 0..<80 where phoneKeys.found.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
            if let phone = byAddress ?? phoneKeys.found.first {
                do {
                    let pairing = try await phoneKeys.beginPairing(with: phone)
                    print("dev link: code \(pairing.outcome.code) with \(pairing.outcome.peer.name) (\(pairing.outcome.peer.id))")
                    try await phoneKeys.finish(pairing, accepted: true)
                    let offered = LinkStore.shared.paired.first { $0.id == pairing.outcome.peer.id }?.identities.count ?? 0
                    print("dev link: paired, phone offers \(offered) key(s), reachable also at \(LinkStore.shared.paired.first?.addresses ?? [])")
                } catch {
                    print("dev link: FAILED \(error)")
                }
            } else {
                print("dev link: no phone found")
            }
            phoneKeys.stopBrowsing()
        }
        // BSNS_DEV_PEERKEY=<hosts>: create an automation key limited to those
        // hosts, write its authorized_keys line to BSNS_DEV_PEERKEY_OUT, serve
        // the agent socket (hardware and automation keys only) knowing the host
        // key of BSNS_DEV_HOST:_PORT, wait, then delete the key again.
        // BSNS_DEV_LEGACY_PLANT=1: put a sync passphrase in the login keychain,
        // as an older build would have, to exercise the move on the next launch.
        if env["BSNS_DEV_LEGACY_PLANT"] == "1" {
            let status = SecItemAdd([
                kSecClass as String: kSecClassGenericPassword,
                kSecUseDataProtectionKeychain as String: false,
                kSecAttrService as String: "cc.bsns.ssh.sync",
                kSecAttrAccount as String: "passphrase",
                kSecValueData as String: Data("legacy-test-value".utf8),
            ] as CFDictionary, nil)
            print("dev legacy: planted status=\(status)")
            return
        }
        // BSNS_DEV_PEERKEY_PURGE=1: delete every automation key (test cleanup).
        if env["BSNS_DEV_PEERKEY_PURGE"] == "1" {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for identity in store.identities where store.peerHosts(of: identity) != nil { await store.deleteKey(identity) }
            print("dev peer key: purged, keys left=\(store.identities.count)")
            return
        }
        if let scope = env["BSNS_DEV_PEERKEY"], let out = env["BSNS_DEV_PEERKEY_OUT"],
           let host = env["BSNS_DEV_HOST"] {
            let port = UInt16(env["BSNS_DEV_PORT"] ?? "22") ?? 22
            do {
                let before = Set(store.identities.map(\.blob))
                try await store.generatePeerKey(hosts: scope.split(separator: ",").map(String.init))
                guard let identity = store.identities.first(where: { !before.contains($0.blob) }) else { return }
                try? (authorizedKeysLine(identity) + "\n").write(toFile: out, atomically: true, encoding: .utf8)
                var known = KnownHosts()
                let probe = SSHShell()
                do {
                    try await probe.connect(host: host, port: port, user: NSUserName(), agent: store.agent, knownHosts: known)
                } catch SSHShellError.unknownHostKey(let hostKey) {
                    known.trust(host: host, port: port, key: hostKey)
                } catch {}
                probe.disconnect()
                print("dev peer key: test server known=\(!known.allEntries.isEmpty)")
                agentSocket.pinned = true
                agentSocket.start(enabled: true, hardwareOnly: true, automationKeys: env["BSNS_DEV_PEERKEY_OFFER"] != "0",
                                  agent: store.agent, knownHosts: known)
                print("dev peer key: ready, limited to \(store.peerHosts(of: identity) ?? []), socket \(agentSocket.state)")
                try? await Task.sleep(nanoseconds: 14_000_000_000)
                await store.deleteKey(identity)
                print("dev peer key: deleted, keys left=\(store.identities.count)")
            } catch {
                print("dev peer key: FAILED \(error)")
            }
            return
        }
        // BSNS_DEV_AGENT_SOCKET=1 serves the agent socket for this run without
        // touching the saved settings; =all also offers software keys.
        if let mode = env["BSNS_DEV_AGENT_SOCKET"], !mode.isEmpty {
            if let seed = env["BSNS_DEV_KEY"].flatMap({ Data(base64Encoded: $0) }),
               let key = try? FileKey.from(algorithm: .ed25519, privateKeyMaterial: seed, comment: "dev key") {
                await store.agent.add(key)
            }
            agentSocket.pinned = true
            agentSocket.start(enabled: true, hardwareOnly: mode != "all", automationKeys: false,
                              agent: store.agent, knownHosts: KnownHosts())
            print("dev agent socket: \(agentSocket.state)")
            // BSNS_DEV_AGENT_SOCKET_STOP_AFTER=<seconds>: turn the agent off again,
            // to check that programs already connected lose their access.
            if let after = env["BSNS_DEV_AGENT_SOCKET_STOP_AFTER"].flatMap(Double.init) {
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                agentSocket.stop()
                print("dev agent socket: stopped")
            }
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

/// A stand-in phone for testing the iCloud relay with one Mac: it holds its
/// own link identity, is "paired" with this Mac for the run, and uses the same
/// record names and sealing a real phone would.
@MainActor
enum DevRelayLoop {
    static func run() async {
        let database = CKContainer(identifier: CloudRelay.containerID).privateCloudDatabase
        let phone = LinkIdentity()
        let mac = LinkStore.shared.identity
        let phonePeer = LinkPeer(publicKey: phone.publicKey, name: "test phone")
        LinkStore.shared.add(phonePeer)
        defer { LinkStore.shared.remove(phonePeer.id) }
        guard let phoneChannel = try? RelayChannel(identity: phone, peer: LinkPeer(publicKey: mac.publicKey, name: "mac")) else { return }
        UserDefaults.standard.set(true, forKey: AskCenter.relayKey)
        AskCenter.shared.applyRelaySetting()
        defer { UserDefaults.standard.removeObject(forKey: AskCenter.relayKey); AskCenter.shared.applyRelaySetting() }

        let ask = Ask(text: "Deploy integration to prod?", options: ["approve", "rollback"], machine: AskCenter.machineName, source: "relay test", lifetime: 120)
        let started = Date()
        async let outcome = AskCenter.shared.ask(ask)

        // The "phone": wait for the sealed ask to appear in iCloud, open it, answer.
        let askID = CKRecord.ID(recordName: RelayChannel.recordName(.ask, askID: ask.id, to: phonePeer.id))
        var received: Ask?
        for _ in 0..<30 {
            if let record = try? await database.record(for: askID), let box = record["box"] as? Data {
                received = try? phoneChannel.open(box, as: .ask)
                print("dev relay: phone found the ask in iCloud after \(String(format: "%.1f", Date().timeIntervalSince(started)))s; stored bytes readable as text: \(String(data: box, encoding: .utf8)?.contains("Deploy") ?? false)")
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // What a phone does to find its asks and to be told about new ones:
        // a query and a subscription on "to" and "kind". Both need indexes.
        do {
            let predicate = NSPredicate(format: "to == %@ AND kind == %d", phonePeer.id, Int(RelayChannel.Kind.ask.rawValue))
            let (results, _) = try await database.records(matching: CKQuery(recordType: CloudRelay.recordType, predicate: predicate), resultsLimit: 10)
            print("dev relay: query for the phone's asks found \(results.count)")
            let subscription = CKQuerySubscription(recordType: CloudRelay.recordType, predicate: predicate,
                                                   subscriptionID: "dev-probe", options: [.firesOnRecordCreation])
            let info = CKSubscription.NotificationInfo()
            info.alertBody = "probe"
            subscription.notificationInfo = info
            _ = try await database.save(subscription)
            _ = try await database.deleteSubscription(withID: "dev-probe")
            print("dev relay: subscription saved and removed")
        } catch {
            print("dev relay: query/subscription FAILED \(error)")
        }
        guard let received else { print("dev relay: FAILED — the ask never appeared in iCloud"); AskCenter.shared.withdraw(ask.id); _ = await outcome; return }
        print("dev relay: phone read: \(received.text) \(received.options)")
        if let box = try? phoneChannel.seal(AskAnswer(askID: received.id, choice: "approve"), as: .answer) {
            let answer = CKRecord(recordType: CloudRelay.recordType,
                                  recordID: CKRecord.ID(recordName: RelayChannel.recordName(.answer, askID: received.id, to: mac.deviceID)))
            answer["to"] = mac.deviceID as NSString
            answer["kind"] = NSNumber(value: RelayChannel.Kind.answer.rawValue)
            answer["box"] = box as NSData
            do { _ = try await database.save(answer) } catch { print("dev relay: answer save FAILED \(error)") }
        }
        let result = await outcome
        print("dev relay: the Mac got \(result) after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let left = (try? await database.record(for: askID)) != nil
        print("dev relay: ask record still in iCloud afterwards: \(left)")
    }
}
#endif
