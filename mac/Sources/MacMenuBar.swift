import SwiftUI
import AppKit
import BsnsSSHCore

/// What is waiting across the user's machines, from the menu bar — so the
/// window needn't be open to know an agent has stopped to ask something.
struct MacMenuBarContent: View {
    let board: MachineBoard
    let sessions: SessionStore
    let surfaces: MacSurfaceCache
    let store: AgentStore
    let knownHosts: KnownHostsStore

    var body: some View {
        // Questions come first: something is blocked until they are answered.
        let asks = AskCenter.shared.pending
        if !asks.isEmpty {
            Section("Waiting for an Answer") {
                ForEach(asks) { ask in
                    Menu("\(ask.source ?? ask.machine): \(ask.text)") {
                        ForEach(ask.options, id: \.self) { option in
                            Button(option) { AskCenter.shared.answer(AskAnswer(askID: ask.id, choice: option)) }
                        }
                    }
                }
            }
        }
        let live = board.machines.filter { $0.overview != nil }
        if live.isEmpty {
            Text("No machines being watched")
        }
        ForEach(live) { machine in
            if let overview = machine.overview {
                Section(header(of: machine, overview: overview)) {
                    let waiting = overview.windows.filter { isWaiting(machine.attention(for: $0)) }
                    if waiting.isEmpty {
                        Text(overview.windows.isEmpty ? "No tmux sessions" : "Nothing waiting")
                    }
                    ForEach(waiting) { window in
                        Button("\(window.session) · \(window.name.isEmpty ? window.command : window.name) — waiting \(waitingFor(machine.attention(for: window), now: overview.now))") {
                            bringForward()
                            MachineActions.open(window, on: machine, board: board, sessions: sessions,
                                                surfaces: surfaces, store: store, knownHosts: knownHosts)
                        }
                        .disabled(!MachineActions.canOpen(window))
                    }
                }
            }
        }
        Divider()
        Button("Open bsns.SSH") { bringForward() }
        Button("Quit") { NSApp.terminate(nil) }
    }

    private func header(of machine: MachineBoard.Machine, overview: TmuxOverview) -> String {
        guard let load = overview.load.first else { return machine.name }
        return "\(machine.name) — load \(String(format: "%.1f", load))\(overview.cpus.map { " on \($0) cores" } ?? "")"
    }

    private func isWaiting(_ state: AttentionTracker.State) -> Bool {
        if case .waiting = state { return true }
        return false
    }

    private func waitingFor(_ state: AttentionTracker.State, now: Int) -> String {
        if case .waiting(let since) = state { return MachineBoard.span(now - since) }
        return ""
    }

    private func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
        }
    }
}
