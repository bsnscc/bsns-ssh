import SwiftUI
import BsnsSSHCore

/// Connect to a host with a key from the agent. Saved hosts fill the form; an
/// unknown host key is shown for the user to check before anything is sent.
struct MacConnectView: View {
    @Environment(AgentStore.self) private var store
    @Environment(HostStore.self) private var hosts
    @Environment(KnownHostsStore.self) private var knownHosts
    @Environment(SessionStore.self) private var sessions
    @Environment(SessionHandoffStore.self) private var handoff

    @State private var host = ""
    @State private var port = "22"
    @State private var user = NSUserName()
    @State private var useMosh = false
    @State private var tmuxSession = ""
    /// Other addresses for the same machine, as typed (see `SavedHost.routes`).
    @State private var routesText = ""
    @State private var presence = HostPresence()
    @State private var keyID: String?
    @State private var busy = false
    @State private var error: String?
    @State private var pendingHostKey: HostKey?

    private var selectedKey: SSHPublicKey? {
        store.identities.first { SSHKeyFormat.fingerprint(ofPublicKeyBlob: $0.blob) == keyID } ?? store.identities.first
    }
    private var portValue: UInt16? { UInt16(port).flatMap { $0 > 0 ? $0 : nil } }
    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !user.isEmpty && portValue != nil
            && selectedKey != nil && !busy
    }

    var body: some View {
        HStack(spacing: 0) {
            if !hosts.hosts.isEmpty {
                savedHosts
                Divider()
            }
            form
        }
        .navigationTitle("Connect")
        .task { await presence.watch { hosts.hosts } }
        .onChange(of: hosts.hosts) { _, saved in presence.refresh(saved) }
        .alert("Trust this host?", isPresented: Binding(get: { pendingHostKey != nil },
                                                        set: { if !$0 { pendingHostKey = nil } }),
               presenting: pendingHostKey) { key in
            Button("Trust and Connect") {
                if let portValue { knownHosts.trust(host: host, port: portValue, key: key) }
                connect()
            }
            Button("Cancel", role: .cancel) { }
        } message: { key in
            Text("\(host) presented a \(key.keyType) key this Mac hasn't seen before:\n\n\(key.fingerprint)\n\nCheck it against the server before trusting it.")
        }
    }

    private var savedHosts: some View {
        List(hosts.hosts) { saved in
            Button { fill(saved) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let state = presence.states[saved.id] {
                            Circle().fill(state == .unreachable ? Color.red : state == .checking ? Color.gray : Color.green)
                                .frame(width: 7, height: 7)
                                .help(state == .unreachable ? "Unreachable" : state == .checking ? "Checking…" : "Reachable")
                        }
                        Text(saved.label.isEmpty ? saved.host : saved.label)
                    }
                    Text("\(saved.user)@\(saved.host)\(saved.port == 22 ? "" : ":\(saved.port)")\(saved.useMosh == true ? " · mosh" : "")\(presenceNote(for: saved))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Remove", role: .destructive) { hosts.remove(saved) }
            }
        }
        .frame(width: 230)
    }

    private var form: some View {
        Form {
            if !handoff.offers.isEmpty {
                Section {
                    ForEach(handoff.offers) { offer in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(offer.session.title)
                                Text(SessionHandoffStore.caption(for: offer))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(offer.continuesWork ? "Continue Here" : "Open Here") {
                                fill(offer)
                                connect()
                            }
                            .disabled(busy)
                        }
                    }
                } header: {
                    Text("On Your Other Devices")
                } footer: {
                    Text("Sessions with a tmux session pick up where the other device left off. Others start a new shell on the same server.")
                }
            }
            Section("Server") {
                TextField("Host", text: $host, prompt: Text("example.com"))
                TextField("Port", text: $port)
                TextField("User", text: $user)
                TextField("Also at", text: $routesText, prompt: Text("Other addresses for this machine — LAN name, tailnet name"))
            }
            Section("Key") {
                if store.identities.isEmpty {
                    Text("No keys yet — create one under Keys.").foregroundStyle(.secondary)
                } else {
                    Picker("Authenticate with", selection: Binding(
                        get: { selectedKey.map { SSHKeyFormat.fingerprint(ofPublicKeyBlob: $0.blob) } ?? "" },
                        set: { keyID = $0 })) {
                        ForEach(store.identities, id: \.blob) { identity in
                            Text(MacKeysView.name(of: identity, hardware: store.isHardware(identity)))
                                .tag(SSHKeyFormat.fingerprint(ofPublicKeyBlob: identity.blob))
                        }
                    }
                }
            }
            Section {
                Toggle("Use mosh (UDP · survives sleep and network changes)", isOn: $useMosh)
                TextField("tmux session", text: $tmuxSession, prompt: Text("optional — attach or create"))
            } footer: {
                Text("With a tmux session named, the connection attaches to it (creating it the first time), so reconnecting — after sleep, a network change or relaunching the app — returns to the same work.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                HStack {
                    Button("Save Host") { save() }
                        .disabled(host.isEmpty || portValue == nil)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Connect") { connect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canConnect)
                }
            }
        }
        .formStyle(.grouped)
        .autocorrectionDisabled()
    }

    private func fill(_ saved: SavedHost) {
        host = saved.host
        port = String(saved.port)
        user = saved.user
        useMosh = saved.useMosh ?? false
        tmuxSession = saved.tmuxSession ?? ""
        routesText = (saved.routes ?? []).joined(separator: ", ")
        keyID = saved.keyID
        error = nil
    }

    private func presenceNote(for saved: SavedHost) -> String {
        switch presence.states[saved.id] {
        case .reachable(let route): return route == saved.host ? "" : " · via \(route)"
        case .unreachable: return " · unreachable"
        default: return ""
        }
    }

    /// Load a session that is open on another device. The key it used there is
    /// chosen if this Mac has it too; a hardware key doesn't travel, so otherwise
    /// the key saved for that host here, or the current choice, is used.
    private func fill(_ offer: HandoffOffer) {
        let s = offer.session
        host = s.host
        port = String(s.port)
        user = s.user
        useMosh = s.useMosh
        tmuxSession = s.tmuxSession ?? ""
        routesText = (hosts.hosts.first { $0.host == s.host && $0.user == s.user }?.routes ?? []).joined(separator: ", ")
        if let blob = s.keyBlob, store.identities.contains(where: { $0.blob == blob }) {
            keyID = SSHKeyFormat.fingerprint(ofPublicKeyBlob: blob)
        } else if let saved = hosts.hosts.first(where: { $0.host == s.host && $0.user == s.user }), let known = saved.keyID {
            keyID = known
        }
        error = nil
    }

    private func save() {
        guard let portValue else { return }
        hosts.add(SavedHost(label: host, host: host, port: Int(portValue), user: user,
                            useMosh: useMosh, keyID: selectedKey.map { SSHKeyFormat.fingerprint(ofPublicKeyBlob: $0.blob) },
                            tmuxSession: MoshBootstrap.sanitizedTmuxName(tmuxSession),
                            routes: { let r = HostRoutes.parse(routesText, excluding: host); return r.isEmpty ? nil : r }()))
    }

    private func connect() {
        guard let portValue, let key = selectedKey else { return }
        let host = host.trimmingCharacters(in: .whitespaces)
        let user = user
        // Addresses typed but not saved still count for this connection.
        RouteBook.shared.set(HostRoutes.parse(routesText, excluding: host), for: host)
        error = nil
        busy = true
        let known = knownHosts.knownHosts
        let agent = store.agent
        let tmux = MoshBootstrap.sanitizedTmuxName(tmuxSession)
        let useMosh = useMosh
        let spec = TerminalSession.Spec(host: host, port: portValue, user: user, agent: agent,
                                        knownHosts: known, useMosh: useMosh, keyBlob: key.blob, tmuxSession: tmux)
        Task {
            do {
                let session: TerminalSession
                if useMosh {
                    // The session id is minted up front: the bootstrap records the
                    // server it starts against it (see MoshServerRegistry).
                    let id = UUID()
                    let connect = try await MoshBootstrap.connect(spec: spec, sessionID: id)
                    let mosh = MoshSession()
                    mosh.serverPID = connect.pid
                    if let failure = mosh.open(host: RouteBook.shared.address(for: host), port: connect.port, key: connect.key, cols: 80, rows: 24) {
                        if let pid = connect.pid {
                            MoshServerRegistry.shared.abandon(
                                pid: pid, hostKey: MoshServerRegistry.hostKey(host: host, port: portValue, user: user))
                        }
                        throw MoshBootstrap.Failure.noConnectLine(failure)
                    }
                    session = TerminalSession(id: id, spec: spec, title: "\(user)@\(host) · mosh")
                    session.adopt(mosh)
                } else {
                    let shell = SSHShell()
                    try await shell.connect(host: host, port: portValue, user: user, agent: agent,
                                            knownHosts: known, keyBlob: key.blob)
                    session = TerminalSession(spec: spec, title: "\(user)@\(host)")
                    session.adopt(shell)
                    session.attachTmuxIfConfigured(shell)
                }
                // Remembered so the session is reopened on the next launch.
                session.restorable = RestorableSession(id: session.id, title: session.title, host: host, port: portValue,
                                                       user: user, useMosh: useMosh, keyBlob: key.blob, tmuxSession: tmux)
                busy = false
                sessions.add(session)
            } catch SSHShellError.unknownHostKey(let hostKey) {
                busy = false
                pendingHostKey = hostKey
            } catch {
                busy = false
                self.error = TerminalSession.describe(error)
            }
        }
    }
}
