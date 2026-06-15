import SwiftUI

@main
struct BsnsSSHApp: App {
    @State private var store = AgentStore()
    @State private var hosts = HostStore()
    @State private var knownHosts = KnownHostsStore()
    @State private var sessions = SessionStore()
    @State private var surfaces = TerminalSurfaceCache()

    init() { SettingsKey.registerDefaults() }

    var body: some Scene {
        WindowGroup {
            LockGate {
                RootView()
                    .environment(store)
                    .environment(hosts)
                    .environment(knownHosts)
                    .environment(sessions)
                    .environment(surfaces)
            }
        }
    }
}
