import Foundation
import Observation
import BsnsSSHCore

/// Runs the panel's tmux commands over one side connection.
@MainActor
@Observable
final class TmuxPanelModel {
    enum State { case connecting, ready, failed(String) }

    static let defaultHistoryLines = 10_000

    private(set) var state = State.connecting
    private(set) var windows: [TmuxCommand.Window] = []
    private(set) var history: String?
    /// Columns of the pane the history came from, for telling a wrapped command
    /// from output.
    private(set) var historyWidth: Int?
    private(set) var error: String?
    private(set) var busy = false

    @ObservationIgnored private let session: TerminalSession
    @ObservationIgnored private var channel: SSHExecSession?

    init(session: TerminalSession) { self.session = session }

    func connect() async {
        channel?.close()
        channel = nil
        state = .connecting
        do {
            channel = try await session.openSideChannel()
            state = .ready
        } catch {
            state = .failed(TerminalSession.describe(error))
        }
    }

    func close() {
        channel?.close()
        channel = nil
    }

    /// Run one tmux command; nil (with `error` set) if it failed.
    private func run(_ command: String, streamCap: Int = SSHShell.execStreamCap) async -> String? {
        guard let channel else { return nil }
        busy = true
        defer { busy = false }
        do {
            let result = try await channel.run(command, streamCap: streamCap)
            guard result.exitStatus == 0 else {
                error = Self.explain(result)
                return nil
            }
            error = nil
            return result.stdoutString
        } catch {
            // The connection dropped under the panel — say so, and let "Try
            // Again" reconnect, rather than failing every command after it.
            state = .failed(TerminalSession.describe(error))
            return nil
        }
    }

    private static func explain(_ result: SSHShell.ExecResult) -> String {
        if result.exitStatus == 127 { return "tmux isn't installed on the server, or isn't on its PATH." }
        let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.contains("no server running") || detail.contains("no tmux client") || detail.contains("error connecting") {
            return "No tmux session is attached to this terminal."
        }
        return detail.isEmpty ? "tmux exited with status \(result.exitStatus)." : String(detail.prefix(240))
    }

    func loadWindows() async {
        guard let output = await run(TmuxCommand.listWindows(session.tmuxTarget)) else { return }
        windows = TmuxCommand.parseWindows(output)
    }

    func select(_ window: TmuxCommand.Window) async -> Bool {
        await run(TmuxCommand.selectWindow(session.tmuxTarget, index: window.index)) != nil
    }

    func newWindow() async -> Bool {
        await run(TmuxCommand.newWindow(session.tmuxTarget)) != nil
    }

    func loadHistory(lines: Int) async {
        guard let output = await run(TmuxCommand.captureHistory(session.tmuxTarget, lines: lines),
                                     streamCap: SSHExecSession.historyStreamCap) else { return }
        // The capture includes the visible screen, which is blank below the
        // cursor; drop that tail so the view ends on the last real line.
        let (width, text) = TmuxCommand.parseHistory(output)
        historyWidth = width
        var rows = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        while let last = rows.last, last.allSatisfy(\.isWhitespace) { rows.removeLast() }
        history = rows.joined(separator: "\n")
    }
}
