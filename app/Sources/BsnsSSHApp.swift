import SwiftUI

@main
struct BsnsSSHApp: App {
    @State private var store = AgentStore()
    @State private var hosts = HostStore()
    @State private var knownHosts = KnownHostsStore()
    @State private var sessions = SessionStore()
    @State private var surfaces = TerminalSurfaceCache()
    @State private var sync = SyncStore()
    @State private var snippets = SnippetStore()
    @State private var sessionRestore = SessionRestoreStore()
    @State private var handoff = SessionHandoffStore()
    @State private var machines = MachineBoard()
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate

    init() {
        SettingsKey.registerDefaults()
        DiagLog.refreshEnabled()
        DiagLog.markLaunch()
        // Any mosh-server started by a previous run of the app is orphaned: its
        // client's crypto state died with the process, so nothing here can ever
        // talk to it again. Mark them reapable by the next connect to that host,
        // or they sit on the host holding a PTY until their idle timeout.
        MoshServerRegistry.shared.markAllAbandonedFromPreviousRun()
    }

    var body: some Scene {
        WindowGroup {
            LockGate {
                RootView()
                    .environment(store)
                    .environment(hosts)
                    .environment(knownHosts)
                    .environment(sessions)
                    .environment(surfaces)
                    .environment(sync)
                    .environment(snippets)
                    .environment(sessionRestore)
                    .environment(handoff)
                    .environment(machines)
            }
        }
        // With a keyboard attached (and in the iPad's menu bar): the same tab
        // shortcuts as on the Mac.
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection") { sessions.goHome() }
                    .keyboardShortcut("t")
                Button("Close Tab") {
                    if let active = sessions.active { surfaces.drop(active.id); sessions.close(active) }
                }
                .keyboardShortcut("w")
                .disabled(sessions.active == nil)
                Button(sessions.pair == nil ? "Split with Next Tab" : "Close Split") {
                    if sessions.pair != nil { sessions.unsplit(); return }
                    let all = sessions.sessions
                    guard let index = all.firstIndex(where: { $0.id == sessions.activeID }), all.count > 1 else { return }
                    sessions.split(with: all[(index + 1) % all.count])
                }
                .keyboardShortcut("d")
                .disabled(sessions.active == nil || (sessions.pair == nil && sessions.sessions.count < 2))
                Button("Other Pane") {
                    if let other = sessions.splitSessions?.first(where: { $0.id != sessions.activeID }) {
                        sessions.activate(other)
                        surfaces.focus(other.id)
                    }
                }
                .keyboardShortcut("j")
                .disabled(sessions.splitSessions == nil)
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
    }

    private func step(_ by: Int) {
        let all = sessions.sessions
        guard !all.isEmpty else { return }
        let current = all.firstIndex { $0.id == sessions.activeID } ?? (by > 0 ? -1 : 0)
        sessions.activate(all[(current + by + all.count) % all.count])
    }
}
