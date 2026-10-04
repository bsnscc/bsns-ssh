import SwiftUI

@main
struct BsnsSSHMacApp: App {
    @State private var store = AgentStore()
    @State private var hosts = HostStore()
    @State private var knownHosts = KnownHostsStore()
    @State private var sessions = SessionStore()
    @State private var surfaces = MacSurfaceCache()

    init() {
        SettingsKey.registerDefaults()
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
                .tint(Brand.accent)
                .frame(minWidth: 760, minHeight: 460)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection") { sessions.goHome() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            MacSettingsView()
        }
    }
}
