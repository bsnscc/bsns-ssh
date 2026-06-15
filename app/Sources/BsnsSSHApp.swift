import SwiftUI

@main
struct BsnsSSHApp: App {
    @State private var store = AgentStore()
    @State private var hosts = HostStore()
    @State private var knownHosts = KnownHostsStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(hosts)
                .environment(knownHosts)
        }
    }
}
