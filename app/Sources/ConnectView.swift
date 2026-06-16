import SwiftUI
import BsnsSSHCore

struct ConnectView: View {
    @Environment(AgentStore.self) private var store
    @Environment(HostStore.self) private var hostStore
    @Environment(KnownHostsStore.self) private var knownHostsStore
    @Environment(SessionStore.self) private var sessions
    @Environment(TerminalSurfaceCache.self) private var surfaces
    @Environment(SnippetStore.self) private var snippetStore

    private enum PendingAction { case connect, install }

    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var group = ""
    @State private var jump = ""
    @State private var password = ""
    @State private var useMosh = false
    @State private var showSFTP = false
    @State private var showImport = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var pendingHostKey: HostKey?
    @State private var pendingAction: PendingAction = .connect

    var body: some View {
        Form {
            if !sessions.sessions.isEmpty {
                Section("Active") {
                    ForEach(sessions.sessions) { s in
                        Button { sessions.activate(s) } label: {
                            HStack {
                                Image(systemName: "terminal").foregroundStyle(.secondary)
                                Text(s.title).foregroundStyle(.primary)
                                Spacer()
                                statusDot(for: s)
                            }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { sessions.sessions[$0] }.forEach { s in
                            surfaces.drop(s.id); sessions.close(s)
                        }
                    }
                }
            }

            ForEach(groupedHosts, id: \.0) { groupName, groupHosts in
                Section(groupName ?? "Saved") {
                    ForEach(groupHosts) { entry in
                        Button { loadHost(entry) } label: { savedRow(entry) }
                    }
                    .onDelete { offsets in offsets.map { groupHosts[$0] }.forEach(hostStore.remove) }
                }
            }

            Section("Server") {
                TextField("host", text: $host)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("port", text: $port).keyboardType(.numberPad)
                TextField("user", text: $user)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("group (optional)", text: $group)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("jump / bastion (optional: user@host[:port])", text: $jump)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Toggle("Use mosh (UDP, survives roaming)", isOn: $useMosh)
                if useMosh {
                    Text("Connects over SSH to start mosh-server, then runs over UDP. Requires mosh-server on the host and a key (agent) — not a password.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                              || (useMosh ? store.identities.isEmpty : (password.isEmpty && store.identities.isEmpty)))
                Button("Install my key (ssh-copy-id)") { attemptInstall() }
                    .disabled(busy || host.isEmpty || user.isEmpty || password.isEmpty || store.identities.isEmpty)
                Button("Browse files (SFTP)") { if let p = UInt16(port), p > 0 { showSFTP = true } }
                    .disabled(busy || host.isEmpty || user.isEmpty || store.identities.isEmpty)
                Button("Save host") { saveHost() }
                    .disabled(host.isEmpty || user.isEmpty)
            }

            Section {
                Button("Import from OpenSSH (config · known_hosts · keys)") { showImport = true }
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
        .sheet(isPresented: $showSFTP) {
            if let p = UInt16(port), p > 0 {
                SFTPBrowserView(host: host, port: p, user: user)
            }
        }
        .sheet(isPresented: $showImport) { ImportConfigView() }
        .alert("Verify host key", isPresented: Binding(get: { pendingHostKey != nil }, set: { if !$0 { pendingHostKey = nil } })) {
            Button("Trust", role: .destructive) { trustAndContinue() }
            Button("Cancel", role: .cancel) { pendingHostKey = nil }
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

    @ViewBuilder private func statusDot(for s: TerminalSession) -> some View {
        switch s.status {
        case .connected: Circle().fill(.green).frame(width: 8, height: 8)
        case .connecting: ProgressView().controlSize(.mini)
        case .disconnected: Circle().fill(.orange).frame(width: 8, height: 8)
        }
    }

    /// Saved hosts grouped by folder: named groups first (alphabetical), then ungrouped.
    private var groupedHosts: [(String?, [SavedHost])] {
        let groups = Dictionary(grouping: hostStore.hosts) { (h: SavedHost) -> String? in
            let g = h.group?.trimmingCharacters(in: .whitespaces)
            return (g?.isEmpty == false) ? g : nil
        }
        let named = groups.keys.compactMap { $0 }.sorted().map { ($0 as String?, groups[$0]!) }
        let ungrouped = groups[nil].map { [(String?.none, $0)] } ?? []
        return named + ungrouped
    }

    @ViewBuilder private func savedRow(_ entry: SavedHost) -> some View {
        let title = entry.label.isEmpty ? "\(entry.user)@\(entry.host)" : entry.label
        let subtitle = "\(entry.user)@\(entry.host):\(entry.port)" + (entry.jump.map { " ⇢ \($0)" } ?? "")
        VStack(alignment: .leading) {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(.primary)
                if entry.useMosh == true { tag("mosh", .green) }
                if entry.jump?.isEmpty == false { tag("via jump", .orange) }
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func loadHost(_ saved: SavedHost) {
        host = saved.host; port = String(saved.port); user = saved.user
        useMosh = saved.useMosh ?? false
        group = saved.group ?? ""; jump = saved.jump ?? ""
    }

    /// Fire "run on connect" snippets once the shell has settled.
    private func runStartupSnippets(on session: TerminalSession) {
        let startup = snippetStore.runOnConnect
        guard !startup.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            for s in startup { session.runCommand(s.command) }
        }
    }

    private func saveHost() {
        hostStore.add(SavedHost(label: "", host: host, port: Int(port) ?? 22, user: user,
                                useMosh: useMosh,
                                jump: jump.trimmingCharacters(in: .whitespaces).isEmpty ? nil : jump.trimmingCharacters(in: .whitespaces),
                                group: group.trimmingCharacters(in: .whitespaces).isEmpty ? nil : group.trimmingCharacters(in: .whitespaces)))
    }

    /// Parse the first hop of a ProxyJump spec ("user@bastion[:port]"); a missing
    /// user falls back to the target user. Returns nil when no jump is set.
    private func parsedJump() -> SSHShell.JumpHop? {
        let spec = jump.trimmingCharacters(in: .whitespaces)
        guard let first = spec.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces),
              !first.isEmpty else { return nil }
        let who: String, hostPort: String
        if let at = first.firstIndex(of: "@") {
            who = String(first[first.startIndex..<at]); hostPort = String(first[first.index(after: at)...])
        } else { who = user; hostPort = first }
        if let colon = hostPort.lastIndex(of: ":"), colon != hostPort.startIndex {
            let h = String(hostPort[hostPort.startIndex..<colon])
            let p = UInt16(hostPort[hostPort.index(after: colon)...]) ?? 22
            return SSHShell.JumpHop(host: h, port: p, user: who)
        }
        return SSHShell.JumpHop(host: hostPort, port: 22, user: who)
    }

    private func attemptConnect() {
        guard let portValue = UInt16(port), portValue > 0 else { error = "Invalid port."; return }
        if useMosh { attemptConnectMosh(portValue); return }
        error = nil; notice = nil; busy = true
        let shell = SSHShell()
        let known = knownHostsStore.knownHosts
        let pw = password.isEmpty ? nil : password
        let hop = parsedJump()
        Task {
            do {
                try await shell.connect(host: host, port: portValue, user: user, agent: store.agent,
                                        knownHosts: known, password: pw, jump: hop)
                await MainActor.run {
                    busy = false
                    let title = hop.map { "\(user)@\(host) ⇢ \($0.host)" } ?? "\(user)@\(host)"
                    let spec = TerminalSession.Spec(host: host, port: portValue, user: user,
                                                    agent: store.agent,
                                                    knownHosts: knownHostsStore.knownHosts, jump: hop)
                    let s = TerminalSession(spec: spec, title: title)
                    s.adopt(shell)
                    sessions.add(s)
                    runStartupSnippets(on: s)
                    password = ""
                }
            } catch let e as SSHShellError {
                await MainActor.run { busy = false; handle(e, action: .connect) }
            } catch {
                await MainActor.run { busy = false; self.error = "\(error)" }
            }
        }
    }

    private func attemptConnectMosh(_ portValue: UInt16) {
        error = nil; notice = nil; busy = true
        let spec = TerminalSession.Spec(host: host, port: portValue, user: user, agent: store.agent,
                                        knownHosts: knownHostsStore.knownHosts, useMosh: true)
        let hostName = host, userName = user
        Task {
            do {
                let connect = try await MoshBootstrap.connect(spec: spec)
                let mosh = MoshSession()
                if let err = mosh.open(host: hostName, port: connect.port, key: connect.key, cols: 80, rows: 24) {
                    throw MoshBootstrap.Failure.noConnectLine(err)
                }
                await MainActor.run {
                    busy = false
                    let s = TerminalSession(spec: spec, title: "\(userName)@\(hostName) · mosh")
                    s.adopt(mosh)
                    sessions.add(s)
                    runStartupSnippets(on: s)
                    password = ""
                }
            } catch let e as SSHShellError {
                await MainActor.run { busy = false; handle(e, action: .connect) }
            } catch {
                await MainActor.run { busy = false; self.error = TerminalSession.describe(error) }
            }
        }
    }

    private func attemptInstall() {
        guard let portValue = UInt16(port), portValue > 0 else { error = "Invalid port."; return }
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
                await MainActor.run { busy = false; self.error = TerminalSession.describe(error) }
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
        default:
            error = TerminalSession.describe(e)
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
