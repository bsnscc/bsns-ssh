import SwiftUI
import AppKit

@main
struct BsnsSSHMacApp: App {
    @State private var store = AgentStore()
    @State private var hosts = HostStore()
    @State private var knownHosts = KnownHostsStore()
    @State private var sessions = SessionStore()
    @State private var surfaces = MacSurfaceCache()
    @State private var agentSocket = AgentSocketController()
    @State private var sync = SyncStore()
    @State private var snippets = SnippetStore()
    @State private var sessionRestore = SessionRestoreStore()
    @State private var didRestore = false

    init() {
        SettingsKey.registerDefaults()
        AgentSocketController.registerDefaults()
        DiagLog.refreshEnabled()
        DiagLog.markLaunch()
        // Any mosh-server started by a previous run is orphaned (its client's
        // crypto state died with the process); let the next connect reap it.
        MoshServerRegistry.shared.markAllAbandonedFromPreviousRun()
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(store)
                .environment(hosts)
                .environment(knownHosts)
                .environment(sessions)
                .environment(surfaces)
                .environment(agentSocket)
                .tint(Brand.accent)
                .frame(minWidth: 760, minHeight: 460)
                .environment(sync)
                .task {
                    // Every use of a key is recorded, whoever asked for it.
                    await store.agent.setAuditor { KeyActivityLog.shared.record($0) }
                    agentSocket.apply(agent: store.agent, knownHosts: knownHosts.knownHosts)
                    sessions.restore = sessionRestore
                    // Pull before restoring, so a session saved on another
                    // device's key or host arrives first.
                    await ConfigSync.autoPull(sync: sync, hosts: hosts, knownHosts: knownHosts, agent: store, snippets: snippets)
                    restoreSessions()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    ConfigSync.autoPush(sync: sync, hosts: hosts, knownHosts: knownHosts, agent: store, snippets: snippets)
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    reconnectAfterWake()
                }
                .onChange(of: knownHosts.knownHosts) { _, known in
                    agentSocket.apply(agent: store.agent, knownHosts: known)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection") { sessions.goHome() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            MacSettingsView()
                .environment(store)
                .environment(hosts)
                .environment(knownHosts)
                .environment(agentSocket)
                .environment(sync)
                .environment(snippets)
        }
    }

    /// Reopen the sessions that were open when the app last quit. A mosh session
    /// with a tmux session re-attaches to the same work; an SSH one likewise
    /// when it has a tmux session, and otherwise starts a fresh shell.
    private func restoreSessions() {
        guard !didRestore else { return }
        didRestore = true
        #if DEBUG
        // A debug run driven by environment hooks shouldn't also reopen whatever
        // an ordinary run left behind.
        if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("BSNS_DEV_") }) { return }
        #endif
        let existing = Set(sessions.sessions.map(\.id))
        for saved in sessionRestore.snapshotForRestore() where !existing.contains(saved.id) {
            let spec = TerminalSession.Spec(host: saved.host, port: saved.port, user: saved.user,
                                            agent: store.agent, knownHosts: knownHosts.knownHosts,
                                            useMosh: saved.useMosh, keyBlob: saved.keyBlob,
                                            tmuxSession: saved.tmuxSession)
            let session = TerminalSession(id: saved.id, spec: spec, title: saved.title)
            session.restorable = saved
            sessions.add(session)
            session.start()
        }
        sessions.goHome()
    }

    /// Sleep kills a TCP connection without telling anyone until something is
    /// written to it. mosh recovers by itself (see MoshSession); an SSH session
    /// is reconnected here once the network has had a moment to come back.
    private func reconnectAfterWake() {
        Task { @MainActor in
            for delay in [3.0, 10.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                for session in sessions.sessions where !session.spec.useMosh && session.isDisconnected {
                    session.reconnect()
                }
            }
        }
    }
}
