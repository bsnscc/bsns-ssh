import SwiftUI
import UserNotifications
import BsnsSSHCore
#if os(macOS)
import AppKit
/// The cache of terminal views, which closing or opening a tab has to tell.
typealias PlatformSurfaceCache = MacSurfaceCache
#else
import UIKit
typealias PlatformSurfaceCache = TerminalSurfaceCache
#endif

/// Every tmux window on every machine, with what each is doing — and which
/// ones are waiting for you.
struct MachinesView: View {
    @Environment(MachineBoard.self) private var board
    @Environment(AgentStore.self) private var store
    @Environment(KnownHostsStore.self) private var knownHosts
    @Environment(SessionStore.self) private var sessions
    @Environment(PlatformSurfaceCache.self) private var surfaces

    var body: some View {
        List {
            ForEach(board.machines) { machine in
                Section {
                    content(of: machine)
                } header: {
                    header(of: machine)
                }
            }
            if board.machines.count <= 1 {
                Section {
                    Text("Save a host under Connect and it appears here. Watching a machine keeps one connection open to it; the key signs once, when watching starts.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Machines")
    }

    @ViewBuilder private func header(of machine: MachineBoard.Machine) -> some View {
        HStack(spacing: 8) {
            Image(systemName: machine.isLocal ? "desktopcomputer" : "server.rack")
            Text(machine.name).font(.headline)
            if let overview = machine.overview, let load = overview.load.first {
                Text("load \(String(format: "%.1f", load))\(overview.cpus.map { " on \($0) cores" } ?? "")")
                    .font(.caption).foregroundStyle(load > Double(overview.cpus ?? 8) ? .orange : .secondary)
            }
            Spacer()
            switch machine.state {
            case .connecting: ProgressView().controlSize(.small)
            case .live where !machine.isLocal: Button("Stop Watching") { board.pause(machine.id) }.controlSize(.small)
            case .idle where !machine.isLocal, .failed where !machine.isLocal:
                Button("Watch") { watch(machine) }.controlSize(.small)
            default: EmptyView()
            }
        }
    }

    @ViewBuilder private func content(of machine: MachineBoard.Machine) -> some View {
        switch machine.state {
        case .failed(let reason):
            Text(reason).foregroundStyle(.red).font(.callout)
        case .idle:
            Text("Not being watched.").foregroundStyle(.secondary).font(.callout)
        case .connecting:
            Text("Connecting…").foregroundStyle(.secondary).font(.callout)
        case .live:
            if let overview = machine.overview {
                if overview.windows.isEmpty {
                    Text("No tmux sessions.").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(overview.windows) { window in
                    row(window, on: machine, now: overview.now)
                }
            }
        }
    }

    private func row(_ window: TmuxOverview.Window, on machine: MachineBoard.Machine, now: Int) -> some View {
        let attention = machine.attention(for: window)
        let openable = MachineActions.canOpen(window)
        return HStack(spacing: 10) {
            Circle().fill(color(of: attention)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(window.session) · \(window.index): \(window.name)")
                Text(caption(window, attention: attention, now: now)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { open(window, on: machine) }
                .controlSize(.small)
                .disabled(!openable)
                .help(openable ? "Attach this tmux session here" : "This session's name has characters the app can't pass to tmux safely")
        }
    }

    private func color(of attention: AttentionTracker.State) -> Color {
        switch attention {
        case .working: return .green
        case .waiting: return .orange
        case .quiet: return .gray.opacity(0.5)
        }
    }

    private func caption(_ window: TmuxOverview.Window, attention: AttentionTracker.State, now: Int) -> String {
        // A window named after its program would otherwise say so twice.
        let what = window.command.isEmpty || window.command == window.name ? "" : "\(window.command) · "
        switch attention {
        case .working: return what + "working"
        case .waiting(let since): return what + "waiting for you · \(MachineBoard.span(now - since))"
        case .quiet: return what + "quiet for \(MachineBoard.span(now - window.lastActivity))"
        }
    }

    // MARK: actions

    private func watch(_ machine: MachineBoard.Machine) {
        guard let host = machine.host else { return }
        AttentionNotifier.shared.prepare()
        board.watch(machine.id, agent: store.agent, knownHosts: knownHosts.knownHosts,
                    keyBlob: MachineActions.key(for: host, store: store))
    }

    private func open(_ window: TmuxOverview.Window, on machine: MachineBoard.Machine) {
        MachineActions.open(window, on: machine, board: board, sessions: sessions, surfaces: surfaces,
                            store: store, knownHosts: knownHosts)
    }
}

@MainActor
enum MachineActions {
    static func key(for host: SavedHost, store: AgentStore) -> Data? { SessionOpener.key(for: host, store: store) }

    static func canOpen(_ window: TmuxOverview.Window) -> Bool {
        MoshBootstrap.sanitizedTmuxName(window.session) == window.session
    }

    /// Bring a window up in this app: its tmux session attached in a tab, with
    /// that window current.
    static func open(_ window: TmuxOverview.Window, on machine: MachineBoard.Machine, board: MachineBoard,
                     sessions: SessionStore, surfaces: PlatformSurfaceCache, store: AgentStore, knownHosts: KnownHostsStore) {
        guard canOpen(window) else { return }
        board.acknowledge(machine: machine.id, window: window.id)
        Task {
            await board.selectWindow(machine: machine.id, session: window.session, index: window.index)
            let title = "\(machine.name) · \(window.session)"
            if let existing = sessions.sessions.first(where: { $0.title == title }) {
                sessions.activate(existing)
                return
            }
            if let host = machine.host {
                SessionOpener.open(host, tmux: window.session, title: title,
                                   sessions: sessions, store: store, knownHosts: knownHosts)
            } else {
                #if os(macOS)
                // This Mac: the tab is tmux itself, not a shell with tmux typed
                // into it. The name was checked against the shell-safe set above.
                LocalShellLauncher.open(sessions: sessions, surfaces: surfaces, store: store,
                                        // Quoted: zsh would otherwise read a leading "=" as "the path of this command".
                                        command: "exec tmux attach -t '=\(window.session)'", title: title)
                #endif
            }
        }
    }
}

/// Tells the user a window is waiting when they aren't looking at the app: a
/// system notification (local — nothing is sent anywhere) and, on a Mac, a Dock bounce.
@MainActor
final class AttentionNotifier {
    static let shared = AttentionNotifier()
    private var asked = false

    /// Ask for permission to show notifications, the first time it matters.
    func prepare() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func announce(_ window: TmuxOverview.Window, on machine: MachineBoard.Machine) {
        #if os(macOS)
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
        #else
        guard UIApplication.shared.applicationState != .active else { return }
        #endif
        let content = UNMutableNotificationContent()
        content.title = "\(machine.name): \(window.session) is waiting"
        content.body = window.name.isEmpty ? window.command : "\(window.name) — \(window.command)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "\(machine.id)/\(window.id)", content: content, trigger: nil))
    }
}
