import SwiftUI
import BsnsSSHCore

struct ConnectView: View {
    @Environment(AgentStore.self) private var store
    @Environment(HostStore.self) private var hostStore
    @Environment(KnownHostsStore.self) private var knownHostsStore
    @Environment(SessionStore.self) private var sessions
    @Environment(TerminalSurfaceCache.self) private var surfaces
    @Environment(SnippetStore.self) private var snippetStore
    @Environment(\.horizontalSizeClass) private var hSize

    /// The home TabView's selection, so the no-keys empty state can switch the
    /// user to the Keys tab. Optional so previews / other call sites still work.
    var homeTab: Binding<String>? = nil

    private enum PendingAction { case connect, install }

    /// A jump host is configured — only the interactive shell tunnels through it
    /// for now, so mosh / SFTP / install-key are disabled (they'd go direct).
    private var hasJump: Bool { !jump.trimmingCharacters(in: .whitespaces).isEmpty }

    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var group = ""
    @State private var jump = ""
    @State private var password = ""
    /// Fingerprint of the key to authenticate with — auth offers only this one.
    @State private var selectedKeyFP = ""
    @State private var useMosh = false
    @State private var showSFTP = false
    @State private var showImport = false
    @State private var busy = false
    /// The saved host the pointer is hovering (iPad) — reveals its quick-connect button.
    @State private var hoveredHostID: UUID?
    @State private var error: String?
    @State private var notice: String?
    @State private var pendingHostKey: HostKey?
    @State private var pendingAction: PendingAction = .connect
    // A bastion (ProxyJump) host key awaiting trust — prompted + trusted under the
    // bastion's own host/port before we ever authenticate to it.
    @State private var pendingJumpKey: HostKey?
    @State private var pendingJumpHost = ""
    @State private var pendingJumpPort: UInt16 = 22

    var body: some View {
        paneLayout
        .navigationTitle("Connect")
        .onAppear { ensureKeySelection() }
        .onChange(of: store.identities) { _, _ in ensureKeySelection() }
        .toolbar {
            if !hostStore.hosts.isEmpty { EditButton() }
        }
        .sheet(isPresented: $showSFTP) {
            if let p = UInt16(port), p > 0 {
                SFTPBrowserView(host: host, port: p, user: user, keyBlob: selectedKey?.blob)
            }
        }
        .sheet(isPresented: $showImport) { ImportConfigView() }
        .alert("Verify host key", isPresented: Binding(get: { pendingHostKey != nil }, set: { if !$0 { pendingHostKey = nil } })) {
            // First-trust is the normal path, not destructive — keep it non-alarming.
            // A changed/mismatched key never reaches this alert; it surfaces as the
            // "HOST KEY CHANGED" error banner instead.
            Button("Trust") { trustAndContinue() }
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
        .alert("Verify jump host key", isPresented: Binding(get: { pendingJumpKey != nil }, set: { if !$0 { pendingJumpKey = nil } })) {
            Button("Trust") { trustJumpAndContinue() }
            Button("Cancel", role: .cancel) { pendingJumpKey = nil }
        } message: {
            if let key = pendingJumpKey {
                Text("""
                First connection to the jump host \(pendingJumpHost):\(pendingJumpPort).

                \(key.keyType)
                \(key.fingerprint)

                You're routing through this bastion to reach \(host). Trust it only if the fingerprint matches what its admin gave you.
                """)
            }
        }
    }

    @ViewBuilder private func statusDot(for s: TerminalSession) -> some View {
        switch s.status {
        case .connected: Circle().fill(s.isStale ? .yellow : .green).frame(width: 8, height: 8)
        case .connecting: ProgressView().controlSize(.mini)
        case .disconnected: Circle().fill(.orange).frame(width: 8, height: 8)
        }
    }

    /// Saved hosts grouped by folder: named groups first (alphabetical), then ungrouped.
    // MARK: layout

    /// Two columns on iPad (saved hosts beside the form), one scroll on iPhone.
    @ViewBuilder private var paneLayout: some View {
        if hSize == .regular {
            HStack(spacing: 0) {
                Form { activeSection; savedSections }
                    .frame(maxWidth: Layout.sidebarWidth)
                Divider()
                Form {
                    serverSection; keySection; passwordSection
                    actionsSection; importSection; messagesSection
                }
            }
        } else {
            Form {
                activeSection; savedSections; serverSection; keySection
                passwordSection; actionsSection; importSection; messagesSection
            }
        }
    }

    @ViewBuilder private var activeSection: some View {
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
    }

    @ViewBuilder private var savedSections: some View {
        if hostStore.hosts.isEmpty {
            Section("Saved") {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "bookmark").font(.title3).foregroundStyle(.secondary)
                    Text("No saved hosts yet").font(.callout.weight(.medium))
                    Text("Fill in a server, then **Save host** to keep it here for one-tap connect.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        ForEach(groupedHosts, id: \.0) { groupName, groupHosts in
            Section(groupName ?? "Saved") {
                ForEach(groupHosts) { entry in
                    HStack(spacing: 8) {
                        Button { loadHost(entry) } label: {
                            savedRow(entry).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // Always visible so it works on touch (not just pointer); hover just
                        // brightens it. Loads the host and connects in one tap.
                        Button { loadHost(entry); attemptConnect() } label: {
                            Image(systemName: "bolt.horizontal.circle.fill").font(.title2).symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Brand.accent)
                        .help("Quick connect")
                        .accessibilityLabel("Quick connect to \(entry.label.isEmpty ? "\(entry.user)@\(entry.host)" : entry.label)")
                        .disabled(busy)
                        .opacity(hoveredHostID == entry.id ? 1 : 0.7)
                    }
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            if hovering { hoveredHostID = entry.id }
                            else if hoveredHostID == entry.id { hoveredHostID = nil }
                        }
                    }
                }
                .onDelete { offsets in offsets.map { groupHosts[$0] }.forEach(hostStore.remove) }
            }
        }
    }

    @ViewBuilder private var serverSection: some View {
        Section("Server") {
            FieldRow(label: "host") {
                TextField("example.com", text: $host).autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("22", text: $port).keyboardType(.numberPad).frame(width: 52).multilineTextAlignment(.trailing)
            }
            FieldRow(label: "user") {
                TextField("root", text: $user).autocorrectionDisabled().textInputAutocapitalization(.never)
            }
            FieldRow(label: "group") {
                TextField("optional", text: $group).autocorrectionDisabled().textInputAutocapitalization(.never)
            }
            FieldRow(label: "jump") {
                TextField("optional · user@host[:port]", text: $jump).autocorrectionDisabled().textInputAutocapitalization(.never)
            }
            Toggle("Use mosh (UDP · survives roaming)", isOn: $useMosh).disabled(hasJump)
            if hasJump {
                Text("Via a jump host, only a shell tunnels through — mosh, SFTP, and key install go direct and are off. The bastion uses your key; any password is for the target only.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if useMosh {
                Text("Starts mosh-server over SSH, then runs over UDP. Needs mosh-server on the host and a key (agent), not a password.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var keySection: some View {
        if !store.identities.isEmpty {
            Section("Key") {
                Picker("Authenticate with", selection: $selectedKeyFP) {
                    ForEach(store.identities, id: \.blob) { id in
                        Text(keyLabel(id)).tag(fp(id))
                    }
                }
                Text("Only this key is offered, so a host that limits auth attempts won't reject you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            // First-run dead-end: with no keys, key/mosh/jump connects are disabled
            // and there's no hint why. Explain it and offer a one-tap way out —
            // generate a key inline (user-initiated, never silent on launch) or jump
            // to the Keys tab. Password login below still works without a key.
            Section("Key") {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "key").font(.title3).foregroundStyle(.secondary)
                    Text("No keys yet").font(.callout.weight(.medium))
                    Text("Key, mosh, and jump-host connections need an SSH key. Generate one to get started, or add your own on the Keys tab. (Password login below works without a key.)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                Button("Generate an Ed25519 key") {
                    // Generation updates store.identities, and ensureKeySelection()
                    // (onChange) auto-selects the new key.
                    Task { await store.generateKey(.ed25519) }
                }
                Button("Add a key on the Keys tab") { homeTab?.wrappedValue = "keys" }
                    .disabled(homeTab == nil)
            }
        }
    }

    @ViewBuilder private var passwordSection: some View {
        Section("Password (optional)") {
            SecureField("for login or installing a key", text: $password).textContentType(.password)
            Text(password.isEmpty
                 ? "Empty: connect with your key (\(store.identities.count) available)."
                 : "Set: connect with the password, or install your key below.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actionsSection: some View {
        Section {
            Button(busy ? "Working…" : (useMosh && !hasJump ? "Connect (mosh)" : "Connect")) { attemptConnect() }
                .buttonStyle(.brand)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .disabled(busy || host.isEmpty || user.isEmpty
                          || (useMosh || hasJump ? store.identities.isEmpty : (password.isEmpty && store.identities.isEmpty)))
            Button("Browse files (SFTP)") { if let p = UInt16(port), p > 0 { showSFTP = true } }
                .disabled(busy || host.isEmpty || user.isEmpty || store.identities.isEmpty || hasJump)
            Button("Install my key (ssh-copy-id)") { attemptInstall() }
                .disabled(busy || host.isEmpty || user.isEmpty || password.isEmpty || store.identities.isEmpty || hasJump)
            Button("Save host") { saveHost() }
                .disabled(host.isEmpty || user.isEmpty)
        }
    }

    @ViewBuilder private var importSection: some View {
        Section {
            Button("Import from OpenSSH (config · known_hosts · keys)") { showImport = true }
        }
    }

    @ViewBuilder private var messagesSection: some View {
        if let notice {
            Section { Text(notice).foregroundStyle(Brand.accent).font(.callout) }
        }
        if let error {
            Section { Text(error).foregroundStyle(.red).font(.callout) }
        }
    }

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

    // MARK: key selection

    private func fp(_ id: SSHPublicKey) -> String { SSHKeyFormat.fingerprint(ofPublicKeyBlob: id.blob) }

    /// The currently chosen identity (the one auth will offer).
    private var selectedKey: SSHPublicKey? { store.identities.first { fp($0) == selectedKeyFP } }

    private func keyLabel(_ id: SSHPublicKey) -> String {
        let kind = store.isSecurityKey(id) ? "FIDO2 security key"
            : store.isYubiKey(id) ? "Smart card"
            : store.isHardware(id) ? "Secure Enclave"
            : id.algorithm.rawValue.replacingOccurrences(of: "ssh-", with: "")
                .replacingOccurrences(of: "ecdsa-sha2-nistp256", with: "ecdsa")
        return id.comment.isEmpty ? kind : "\(id.comment) · \(kind)"
    }

    /// Keep a valid key selected (default to the first) — auth always offers
    /// exactly one chosen key, so the picker must never be empty when keys exist.
    private func ensureKeySelection() {
        if !store.identities.contains(where: { fp($0) == selectedKeyFP }) {
            selectedKeyFP = store.identities.first.map(fp) ?? ""
        }
    }

    private func loadHost(_ saved: SavedHost) {
        host = saved.host; port = String(saved.port); user = saved.user
        useMosh = saved.useMosh ?? false
        group = saved.group ?? ""; jump = saved.jump ?? ""
        // Restore the saved key if it still exists, else fall back to the default.
        if let kid = saved.keyID, store.identities.contains(where: { fp($0) == kid }) {
            selectedKeyFP = kid
        } else {
            ensureKeySelection()
        }
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
                                group: group.trimmingCharacters(in: .whitespaces).isEmpty ? nil : group.trimmingCharacters(in: .whitespaces),
                                keyID: selectedKeyFP.isEmpty ? nil : selectedKeyFP))
    }

    private enum JumpParseError: Error { case invalidPort }

    /// Parse the first hop of a ProxyJump spec ("user@bastion[:port]"); a missing
    /// user falls back to the target user. Returns nil when no jump is set, and
    /// throws when a port is given but isn't a valid 1...65535 (no silent fallback
    /// to 22 that could authenticate to / trust the wrong bastion endpoint).
    private func parsedJump() throws -> SSHShell.JumpHop? {
        let spec = jump.trimmingCharacters(in: .whitespaces)
        guard let first = spec.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces),
              !first.isEmpty else { return nil }
        let who: String, hostPort: String
        if let at = first.firstIndex(of: "@") {
            who = String(first[first.startIndex..<at]); hostPort = String(first[first.index(after: at)...])
        } else { who = user; hostPort = first }
        if let colon = hostPort.lastIndex(of: ":"), colon != hostPort.startIndex {
            let h = String(hostPort[hostPort.startIndex..<colon])
            guard let p = UInt16(hostPort[hostPort.index(after: colon)...]), p > 0 else {
                throw JumpParseError.invalidPort
            }
            return SSHShell.JumpHop(host: h, port: p, user: who)
        }
        return SSHShell.JumpHop(host: hostPort, port: 22, user: who)
    }

    private func attemptConnect() {
        guard let portValue = UInt16(port), portValue > 0 else { error = "Invalid port."; return }
        if useMosh && !hasJump { attemptConnectMosh(portValue); return }   // jump ⇒ shell only
        let hop: SSHShell.JumpHop?
        do { hop = try parsedJump() }
        catch { self.error = "Jump host port must be a number from 1 to 65535."; return }
        error = nil; notice = nil; busy = true
        let shell = SSHShell()
        let known = knownHostsStore.knownHosts
        let pw = password.isEmpty ? nil : password
        let keyBlob = selectedKey?.blob
        Task {
            do {
                try await shell.connect(host: host, port: portValue, user: user, agent: store.agent,
                                        knownHosts: known, password: pw, jump: hop, keyBlob: keyBlob)
                await MainActor.run {
                    busy = false
                    let title = hop.map { "\(user)@\(host) ⇢ \($0.host)" } ?? "\(user)@\(host)"
                    let spec = TerminalSession.Spec(host: host, port: portValue, user: user,
                                                    agent: store.agent,
                                                    knownHosts: knownHostsStore.knownHosts, jump: hop,
                                                    keyBlob: keyBlob)
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
                                        knownHosts: knownHostsStore.knownHosts, useMosh: true,
                                        keyBlob: selectedKey?.blob)
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
        // Install just the chosen key (the one you'll authenticate with), not every key.
        let lines = (selectedKey.map { [$0] } ?? store.identities).map(authorizedKeysLine)
        let known = knownHostsStore.knownHosts
        let pw = password
        Task {
            do {
                try await SSHShell.installPublicKeys(lines, host: host, port: portValue, user: user,
                                                     password: pw, knownHosts: known)
                await MainActor.run {
                    busy = false
                    password = ""   // don't keep the password in UI state after use
                    notice = "Installed \(lines.count) key(s). Tap Connect."
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
        case let .unknownJumpHostKey(key, jumpHost, jumpPort):
            pendingJumpKey = key; pendingJumpHost = jumpHost; pendingJumpPort = jumpPort
            pendingAction = action
        case .hostKeyMismatch(let stored, let presented):
            error = "⚠️ HOST KEY CHANGED — possible interception.\nstored: \(stored)\nnow:    \(presented)"
        case .jumpHostKeyMismatch(let stored, let presented):
            error = "⚠️ JUMP HOST KEY CHANGED — possible interception.\nstored: \(stored)\nnow:    \(presented)"
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

    private func trustJumpAndContinue() {
        guard let key = pendingJumpKey else { return }
        knownHostsStore.trust(host: pendingJumpHost, port: pendingJumpPort, key: key)
        pendingJumpKey = nil
        switch pendingAction {
        case .connect: attemptConnect()
        case .install: attemptInstall()
        }
    }
}
