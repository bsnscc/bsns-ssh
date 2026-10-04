import SwiftUI

@main
struct BsnsSSHMacApp: App {
    @State private var store = AgentStore()
    @State private var hosts = HostStore()
    @State private var knownHosts = KnownHostsStore()
    @State private var sessions = SessionStore()
    @State private var surfaces = MacSurfaceCache()
    @State private var agentSocket = AgentSocketController()

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
                .task {
                    // Every use of a key is recorded, whoever asked for it.
                    await store.agent.setAuditor { KeyActivityLog.shared.record($0) }
                    agentSocket.apply(agent: store.agent, knownHosts: knownHosts.knownHosts)
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
                .environment(knownHosts)
                .environment(agentSocket)
        }
    }
}
