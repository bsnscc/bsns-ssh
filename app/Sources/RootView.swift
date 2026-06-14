import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { KeysView() }
                .tabItem { Label("Keys", systemImage: "key.fill") }
            NavigationStack { TerminalScreen() }
                .tabItem { Label("Terminal", systemImage: "terminal.fill") }
        }
    }
}
