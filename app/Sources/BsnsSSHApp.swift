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

    init() {
        SettingsKey.registerDefaults()
        DiagLog.markLaunch()
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
            }
        }
    }
}
