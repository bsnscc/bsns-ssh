import SwiftUI
import BsnsSSHCore
import AppKit

@main
struct BsnsSSHMacApp: App {
    @State private var store = AgentStore()
    @State private var hosts = HostStore()
    @State private var knownHosts = KnownHostsStore()
    @State private var sessions = SessionStore()
    @State private var surfaces = MacSurfaceCache()
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var agentSocket = AgentSocketController()
    @State private var phoneKeys = PhoneKeyClient()
    @State private var handoff = SessionHandoffStore()
    @State private var machines = MachineBoard()
    @State private var sync = SyncStore()
    @State private var snippets = SnippetStore()
    @State private var sessionRestore = SessionRestoreStore()
    @State private var didRestore = false

    init() {
        SettingsKey.registerDefaults()
        AgentSocketController.registerDefaults()
        // A peer closing a socket mid-write is an error to handle, not a
        // signal that ends the process.
        signal(SIGPIPE, SIG_IGN)
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
                .environment(phoneKeys)
                .environment(handoff)
                .environment(machines)
                .tint(Brand.accent)
                .frame(minWidth: 760, minHeight: 460)
                .environment(sync)
                .task {
                    // Every use of a key is recorded, whoever asked for it.
                    await store.agent.setAuditor { KeyActivityLog.shared.record($0) }
                    agentSocket.apply(agent: store.agent, knownHosts: knownHosts.knownHosts)
                    await phoneKeys.attach(to: store)
                    sessions.restore = sessionRestore
                    // Pull before restoring, so a session saved on another
                    // device's key or host arrives first.
                    await ConfigSync.autoPull(sync: sync, hosts: hosts, knownHosts: knownHosts, agent: store, snippets: snippets)
                    restoreSessions()
                    // This Mac's own tmux is always on the board; other machines
                    // are watched when asked, since that takes a signature.
                    machines.onAttention = { machine, window in AttentionNotifier.shared.announce(window, on: machine) }
                    machines.sync(hosts: hosts.hosts, localName: Host.current().localizedName ?? "This Mac")
                    machines.watchLocal()
                    watchMachinesUnattended()
                    handoff.publish(sessionRestore.sessions, sync: sync)
                    await handoff.refresh(sync: sync)
                }
                .onChange(of: hosts.hosts) { _, saved in
                    machines.sync(hosts: saved, localName: Host.current().localizedName ?? "This Mac")
                }
                .onChange(of: sessionRestore.sessions) { _, open in
                    handoff.publish(open, sync: sync)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // Coming back to the Mac is when a session left open elsewhere matters.
                    handoff.publish(sessionRestore.sessions, sync: sync)
                    Task { await handoff.refresh(sync: sync) }
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
                Button("New Local Shell") { LocalShellLauncher.open(sessions: sessions, surfaces: surfaces, store: store) }
                    .keyboardShortcut("t")
                Divider()
                // ⌘W closes the tab being looked at; with none, the window.
                Button(sessions.active == nil ? "Close Window" : "Close Tab") {
                    if let active = sessions.active {
                        LocalShellLauncher.close(active, sessions: sessions, surfaces: surfaces)
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w")
                Button("Next Tab") { step(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(sessions.sessions.count < 2)
                Button("Previous Tab") { step(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(sessions.sessions.count < 2)
                ForEach(Array(sessions.sessions.prefix(9).enumerated()), id: \.element.id) { index, session in
                    Button(session.title) { sessions.activate(session) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
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
                .environment(handoff)
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

    private func step(_ by: Int) {
        let all = sessions.sessions
        guard !all.isEmpty else { return }
        let current = all.firstIndex { $0.id == sessions.activeID } ?? (by > 0 ? -1 : 0)
        sessions.activate(all[(current + by + all.count) % all.count])
    }

    /// Hosts whose key is an automation key allowed to sign in to them can be
    /// watched without a prompt, so they are — now, and again every so often in
    /// case the connection dropped or the machine came back.
    private func watchMachinesUnattended() {
        Task { @MainActor in
            while !Task.isCancelled {
                machines.watchUnattended(agent: store.agent, knownHosts: knownHosts.knownHosts) { host in
                    guard let wanted = host.keyID,
                          let identity = store.identities.first(where: { SSHKeyFormat.fingerprint(ofPublicKeyBlob: $0.blob) == wanted }),
                          let allowed = store.peerHosts(of: identity), allowed.contains(host.host.lowercased()) else { return nil }
                    return identity.blob
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    /// Sleep kills a TCP connection without telling anyone until something is
    /// written to it. mosh recovers by itself (see MoshSession); an SSH session
    /// is reconnected here once the network has had a moment to come back.
    private func reconnectAfterWake() {
        Task { @MainActor in
            for delay in [3.0, 10.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                for session in sessions.sessions where !session.spec.useMosh && !session.isLocal && session.isDisconnected {
                    session.reconnect()
                }
            }
        }
    }
}

/// Guarantees the app comes up with its window. The system's saved window state
/// can record "none open" (a quit with the window closed), and the next launch
/// then shows nothing at all; the app reopens its own sessions, so it always
/// wants a window.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            guard !hasWindow, let delegate = NSApp.delegate else { return }
            // The same path as clicking the Dock icon with no window open.
            _ = delegate.applicationOpenUntitledFile?(NSApp)
        }
    }
}
