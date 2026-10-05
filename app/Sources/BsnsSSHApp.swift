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
            }
        }
    }
}
