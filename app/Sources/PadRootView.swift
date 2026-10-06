import SwiftUI
import BsnsSSHCore

/// Whether the terminal is shown beside a sidebar that already lists the
/// sessions (an iPad at full width), so it needn't carry its own tab strip.
private struct SidebarLayoutKey: EnvironmentKey {
    static let defaultValue: Binding<NavigationSplitViewVisibility>? = nil
}

extension EnvironmentValues {
    /// Set when a sidebar lists the sessions; lets the terminal show or hide it.
    var sidebarVisibility: Binding<NavigationSplitViewVisibility>? {
        get { self[SidebarLayoutKey.self] }
        set { self[SidebarLayoutKey.self] = newValue }
    }
}

/// The layout for a wide screen: everything that needs attention down the
/// side — sessions, what is waiting, the machines — and the work beside it.
/// A phone, or an iPad squeezed into a narrow slot, keeps the tabbed layout.
struct PadRootView: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(TerminalSurfaceCache.self) private var surfaces
    @Environment(MachineBoard.self) private var machines
    @State private var inbox = PhoneInbox.shared
    @State private var visibility: NavigationSplitViewVisibility = .all
    @Binding var place: String

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List {
                Section {
                    row("Connect", "network", "connect")
                    row(inbox.items.isEmpty ? "Inbox" : "Inbox (\(inbox.items.count))", "tray", "inbox")
                    row(machines.waitingCount == 0 ? "Machines" : "Machines (\(machines.waitingCount) waiting)",
                        "square.stack.3d.up", "machines")
                    row("Workspaces", "folder", "workspaces")
                    row("Keys", "key.fill", "keys")
                    row("Settings", "gearshape", "settings")
                }
                if !sessions.sessions.isEmpty {
                    Section("Sessions") {
                        ForEach(sessions.sessions) { session in
                            HStack(spacing: 8) {
                                statusDot(session)
                                Text(session.title).lineLimit(1)
                                Spacer()
                                Button {
                                    surfaces.drop(session.id); sessions.close(session)
                                } label: {
                                    Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Close \(session.title)")
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { sessions.activate(session) }
                            .listRowBackground(sessions.activeID == session.id ? Brand.accent.opacity(0.18) : Color.clear)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("bsns.SSH")
        } detail: {
            if let active = sessions.active {
                NavigationStack {
                    LiveTerminalScreen(session: active)
                        .id(active.id)
                }
                .environment(\.sidebarVisibility, $visibility)
            } else {
                NavigationStack { content }
            }
        }
        // Side by side in portrait too, rather than the sidebar covering the work.
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder private var content: some View {
        switch place {
        case "inbox": PadInboxView()
        case "machines": MachinesView()
        case "workspaces": WorkspacesView()
        case "keys": KeysView()
        case "settings": SettingsView()
        default:
            // The connect screen splits into two panes of its own when it has
            // the room; beside a sidebar in portrait it doesn't.
            GeometryReader { area in
                ConnectView(homeTab: $place)
                    .environment(\.horizontalSizeClass, area.size.width < 760 ? .compact : .regular)
            }
        }
    }

    private func row(_ title: String, _ symbol: String, _ tag: String) -> some View {
        Button {
            place = tag
            sessions.goHome()
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(sessions.activeID == nil && place == tag ? Brand.accent.opacity(0.18) : Color.clear)
    }

    @ViewBuilder private func statusDot(_ session: TerminalSession) -> some View {
        switch session.status {
        case .connected: Circle().fill(session.isStale ? .yellow : .green).frame(width: 7, height: 7)
        case .connecting: ProgressView().controlSize(.mini)
        case .disconnected: Circle().fill(.orange).frame(width: 7, height: 7)
        }
    }
}

/// The inbox as its own screen: what is waiting, and the switch that turns
/// delivery on.
struct PadInboxView: View {
    @State private var inbox = PhoneInbox.shared

    var body: some View {
        Form {
            PhoneInboxSection()
            if inbox.enabled, inbox.items.isEmpty {
                Section { Text("Nothing is waiting.").foregroundStyle(.secondary) }
            }
            PhoneInboxSettings()
        }
        .navigationTitle("Inbox")
        .refreshable { await inbox.refresh() }
    }
}
