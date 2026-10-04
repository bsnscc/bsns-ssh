import SwiftUI
import BsnsSSHCore

/// One window: a sidebar of places (connect, keys) and live sessions, and the
/// selected one on the right. Sessions keep running when another row is
/// selected — a terminal is only torn down when its session is closed.
struct MacRootView: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(MacSurfaceCache.self) private var surfaces
    @Environment(AgentStore.self) private var store
    @Environment(AgentSocketController.self) private var agentSocket
    @Environment(PhoneKeyClient.self) private var phoneKeys
    @Environment(SyncStore.self) private var sync
    @Environment(SessionHandoffStore.self) private var handoff

    private enum Place: Hashable { case connect, keys }
    @State private var place: Place = .connect

    var body: some View {
        NavigationSplitView {
            List {
                Section {
                    row("Connect", systemImage: "network", selected: sessions.activeID == nil && place == .connect) {
                        place = .connect
                        sessions.goHome()
                    }
                    row("Keys", systemImage: "key.fill", selected: sessions.activeID == nil && place == .keys) {
                        place = .keys
                        sessions.goHome()
                    }
                }
                if !sessions.sessions.isEmpty {
                    Section("Sessions") {
                        ForEach(sessions.sessions) { session in
                            SessionRow(session: session, selected: sessions.activeID == session.id,
                                       select: { sessions.activate(session) },
                                       close: { surfaces.drop(session.id); sessions.close(session) })
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            if let active = sessions.active {
                MacTerminalScreen(session: active)
                    .id(active.id)
            } else if place == .keys {
                MacKeysView()
            } else {
                MacConnectView()
            }
        }
        #if DEBUG
        .task { await MacDevHooks.run(store: store, sessions: sessions, agentSocket: agentSocket, phoneKeys: phoneKeys,
                                       sync: sync, handoff: handoff) }
        #endif
    }

    private func row(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Brand.accent.opacity(0.18) : Color.clear)
    }
}

private struct SessionRow: View {
    let session: TerminalSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            statusDot
            Button(action: select) {
                Text(session.title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: close) {
                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close session")
            .accessibilityLabel("Close \(session.title)")
        }
        .listRowBackground(selected ? Brand.accent.opacity(0.18) : Color.clear)
    }

    @ViewBuilder private var statusDot: some View {
        switch session.status {
        // Amber when connected-but-stale (mosh has lost contact) — not a reassuring green.
        case .connected: Circle().fill(session.isStale ? .yellow : .green).frame(width: 7, height: 7)
        case .connecting: ProgressView().controlSize(.mini)
        case .disconnected: Circle().fill(.orange).frame(width: 7, height: 7)
        }
    }
}
