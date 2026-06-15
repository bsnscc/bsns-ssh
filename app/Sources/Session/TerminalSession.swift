import Foundation
import Observation
import BsnsSSHCore

/// Owns the live `SSHShell` for one terminal and survives it: tracks connection
/// status, forwards I/O, and can rebuild the shell from a stored spec for
/// one-tap reconnect. The terminal view talks to the session, not the shell, so
/// a reconnect swaps the underlying shell without the view knowing.
@Observable
final class TerminalSession: @unchecked Sendable {
    enum Status: Equatable {
        case connecting
        case connected
        case disconnected(reason: String?)   // nil = clean / user-initiated
    }

    /// Everything needed to re-establish the connection.
    struct Spec {
        let host: String
        let port: UInt16
        let user: String
        let password: String?
        let agent: Agent
        var knownHosts: KnownHosts
    }

    private(set) var status: Status = .connecting
    let spec: Spec
    let title: String

    /// Set by the terminal coordinator; receives shell output (called off-main —
    /// the coordinator hops to main itself, matching SSHShell's existing contract).
    var onOutput: (@Sendable (ArraySlice<UInt8>) -> Void)?

    private let lock = NSLock()
    private var shell: SSHShell?
    private var cols: Int32 = 80
    private var rows: Int32 = 24

    init(spec: Spec, title: String) {
        self.spec = spec
        self.title = title
    }

    /// Adopt an already-connected shell — the initial connect (and its TOFU
    /// prompt) is handled by ConnectView before the terminal appears.
    func adopt(_ shell: SSHShell) {
        wire(shell)
        lock.lock(); self.shell = shell; lock.unlock()
        setStatus(.connected)
    }

    func write(_ bytes: ArraySlice<UInt8>) { currentShell?.write(bytes) }

    func resize(cols: Int32, rows: Int32) {
        lock.lock(); self.cols = cols; self.rows = rows; let s = shell; lock.unlock()
        s?.resize(cols: cols, rows: rows)
    }

    func disconnect() { currentShell?.disconnect() }

    var isDisconnected: Bool { if case .disconnected = status { return true } else { return false } }

    /// Rebuild the shell and reconnect with the stored spec + last known size.
    func reconnect() {
        guard isDisconnected else { return }
        setStatus(.connecting)
        let shell = SSHShell()
        wire(shell)
        lock.lock(); self.shell = shell; let cols = self.cols, rows = self.rows; lock.unlock()
        let spec = self.spec
        Task {
            do {
                try await shell.connect(host: spec.host, port: spec.port, user: spec.user,
                                        agent: spec.agent, cols: cols, rows: rows,
                                        knownHosts: spec.knownHosts, password: spec.password)
                self.setStatus(.connected)
            } catch {
                self.setStatus(.disconnected(reason: Self.describe(error)))
            }
        }
    }

    // MARK: internals

    private var currentShell: SSHShell? { lock.lock(); defer { lock.unlock() }; return shell }

    private func wire(_ shell: SSHShell) {
        shell.onOutput = { [weak self] bytes in self?.onOutput?(bytes) }
        shell.onClosed = { [weak self] reason in
            self?.setStatus(.disconnected(reason: reason))
        }
    }

    private func setStatus(_ s: Status) {
        DispatchQueue.main.async { self.status = s }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case SSHShellError.connectFailed: return "couldn't reach the server"
        case SSHShellError.handshakeFailed: return "handshake failed"
        case SSHShellError.authFailed(let m): return "auth failed: \(m)"
        case SSHShellError.hostKeyMismatch: return "⚠️ host key changed"
        case SSHShellError.unknownHostKey: return "host key no longer trusted"
        default: return "\(error)"
        }
    }
}
