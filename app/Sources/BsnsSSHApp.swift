import SwiftUI

@main
struct BsnsSSHApp: App {
    @State private var store = AgentStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}
