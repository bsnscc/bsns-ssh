import Foundation
import BsnsSSHCore

/// Opens a session to a saved host from anywhere that isn't the connect form:
/// a link, a workspace, the Machines view, a shortcut. Only saved hosts, whose
/// host keys the user has already trusted — nothing here prompts or trusts.
@MainActor
enum SessionOpener {
    /// The key saved for a host, if this device holds it.
    static func key(for host: SavedHost, store: AgentStore) -> Data? {
        guard let wanted = host.keyID else { return nil }
        return store.identities.first { SSHKeyFormat.fingerprint(ofPublicKeyBlob: $0.blob) == wanted }?.blob
    }

    /// The saved host a name refers to: its address or its label.
    static func savedHost(named name: String, user: String? = nil, in hosts: [SavedHost]) -> SavedHost? {
        hosts.first { host in
            (host.host.caseInsensitiveCompare(name) == .orderedSame
                || (!host.label.isEmpty && host.label.caseInsensitiveCompare(name) == .orderedSame))
                && (user == nil || host.user == user)
        }
    }

    /// Bring up a session on `host`, attaching `tmux` if named (created in
    /// `directory` the first time). An open session for the same work is
    /// switched to instead. Nil for hosts reached through a jump host, which
    /// only the connect form can open.
    @discardableResult
    static func open(_ host: SavedHost, tmux: String?, directory: String? = nil, title: String? = nil, workspace: Workspace? = nil,
                     sessions: SessionStore, store: AgentStore, knownHosts: KnownHostsStore) -> TerminalSession? {
        guard (host.jump ?? "").isEmpty else { return nil }
        let session = MoshServerCommand.sanitizedTmuxName(tmux)
        if let session, let existing = sessions.sessions.first(where: {
            !$0.isLocal && $0.spec.host == host.host && $0.spec.user == host.user && $0.spec.tmuxSession == session
        }) {
            sessions.activate(existing)
            return existing
        }
        let port = UInt16(clamping: host.port)
        let useMosh = host.useMosh ?? false
        let spec = TerminalSession.Spec(host: host.host, port: port, user: host.user, agent: store.agent,
                                        knownHosts: knownHosts.knownHosts, useMosh: useMosh,
                                        keyBlob: key(for: host, store: store), tmuxSession: session,
                                        tmuxDirectory: directory, workspace: workspace)
        let name = title ?? (host.label.isEmpty ? "\(host.user)@\(host.host)" : host.label) + (session.map { " · \($0)" } ?? "")
        let opened = TerminalSession(spec: spec, title: name)
        opened.restorable = RestorableSession(id: opened.id, title: name, host: host.host, port: port, user: host.user,
                                              useMosh: useMosh, keyBlob: spec.keyBlob, tmuxSession: session,
                                              tmuxDirectory: directory, workspace: workspace)
        sessions.add(opened)
        opened.start()
        return opened
    }

    /// Follow a link. Returns what went wrong, for showing to the user.
    static func follow(_ url: URL, hosts: HostStore, sessions: SessionStore, store: AgentStore,
                       knownHosts: KnownHostsStore) -> String? {
        guard let link = DeepLink(url) else { return "That link isn't one this app understands." }
        switch link {
        case let .session(name, user, tmux):
            guard let host = savedHost(named: name, user: user, in: hosts.hosts) else {
                return "No saved host is called “\(name)”. Links only open hosts you have saved."
            }
            guard open(host, tmux: tmux, sessions: sessions, store: store, knownHosts: knownHosts) != nil else {
                return "“\(name)” is reached through a jump host; open it from Connect."
            }
            return nil
        case let .workspace(name, hostName):
            guard let workspace = WorkspaceStore.shared.workspaces.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { return "There is no workspace called “\(name)”." }
            let candidates = workspace.hosts.compactMap { savedHost(named: $0, in: hosts.hosts) }
            let chosen = hostName.flatMap { wanted in candidates.first { $0.host.caseInsensitiveCompare(wanted) == .orderedSame || $0.label.caseInsensitiveCompare(wanted) == .orderedSame } }
                ?? (hostName == nil ? candidates.first : nil)
            guard let host = chosen else { return "“\(name)” isn't on a saved host called “\(hostName ?? "any")”." }
            guard open(workspace, on: host, sessions: sessions, store: store, knownHosts: knownHosts) != nil else {
                return "“\(host.host)” is reached through a jump host; open it from Connect."
            }
            return nil
        }
    }

    /// Open a workspace on one of its hosts: its tmux session, started in the
    /// project directory if it doesn't exist yet.
    @discardableResult
    static func open(_ workspace: Workspace, on host: SavedHost, sessions: SessionStore, store: AgentStore,
                     knownHosts: KnownHostsStore) -> TerminalSession? {
        open(host, tmux: workspace.tmuxSession, directory: workspace.path(on: host.host),
             title: "\(workspace.name) · \(host.label.isEmpty ? host.host : host.label)", workspace: workspace,
             sessions: sessions, store: store, knownHosts: knownHosts)
    }
}
