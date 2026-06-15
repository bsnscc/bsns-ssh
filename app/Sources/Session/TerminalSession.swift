import Foundation
import Observation
import BsnsSSHCore

/// Owns the live `SSHShell` for one terminal and survives it: tracks connection
/// status, forwards I/O, and can rebuild the shell from a stored spec for
/// one-tap reconnect. The terminal view talks to the session, not the shell, so
/// a reconnect swaps the underlying shell without the view knowing.
@Observable
final class TerminalSession: Identifiable, @unchecked Sendable {
    let id = UUID()

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
        let agent: Agent
        var knownHosts: KnownHosts
        var useMosh: Bool = false
        // Note: no password is retained. Reconnect uses the agent (keys); a
        // password-only session must be re-established from the Connect screen.
    }

    private(set) var status: Status = .connecting
    let spec: Spec
    let title: String

    /// Set by the terminal coordinator; receives shell output (called off-main —
    /// the coordinator hops to main itself, matching SSHShell's existing contract).
    var onOutput: (@Sendable (ArraySlice<UInt8>) -> Void)?

    private let lock = NSLock()
    /// A configured local (-L) forward. Survives reconnect (re-applied to the
    /// new shell). `error` is non-nil if the local bind failed.
    struct Forward: Identifiable, Equatable {
        let id: UUID
        let listenPort: UInt16
        let destHost: String
        let destPort: UInt16
        var error: String?
    }
    private(set) var forwards: [Forward] = []

    private var transport: TerminalTransport?
    private var cols: Int32 = 80
    private var rows: Int32 = 24

    /// Mosh has no in-session forwarding, so forwards only apply to an SSH shell.
    private var sshShell: SSHShell? { currentTransport as? SSHShell }

    init(spec: Spec, title: String) {
        self.spec = spec
        self.title = title
    }

    /// Add a local forward and start it on the current shell. Returns nil on
    /// success or an error string (e.g. the local port is in use).
    @discardableResult
    func addForward(listenPort: UInt16, destHost: String, destPort: UInt16) -> String? {
        // Forwarding is multiplexed over the SSH channel — mosh (UDP) has none.
        guard let shell = sshShell else { return "Port forwarding isn't available over mosh." }
        let id = UUID()
        let err = shell.addLocalForward(id: id, bindAddress: "127.0.0.1",
                                        listenPort: listenPort, destHost: destHost, destPort: destPort)
        forwards.append(Forward(id: id, listenPort: listenPort, destHost: destHost, destPort: destPort, error: err))
        return err
    }

    func removeForward(_ id: UUID) {
        sshShell?.removeLocalForward(id: id)
        forwards.removeAll { $0.id == id }
    }

    /// Re-establish all configured forwards on the current shell (after reconnect).
    private func reapplyForwards() {
        guard let shell = sshShell else { return }
        for i in forwards.indices {
            let f = forwards[i]
            forwards[i].error = shell.addLocalForward(id: f.id, bindAddress: "127.0.0.1",
                                                      listenPort: f.listenPort, destHost: f.destHost, destPort: f.destPort)
        }
    }

    /// Adopt an already-connected transport — the initial connect (and its TOFU
    /// prompt) is handled by ConnectView before the terminal appears.
    func adopt(_ transport: TerminalTransport) {
        wire(transport)
        lock.lock(); self.transport = transport; lock.unlock()
        setStatus(.connected)
    }

    func write(_ bytes: ArraySlice<UInt8>) { currentTransport?.write(bytes) }

    func resize(cols: Int32, rows: Int32) {
        lock.lock(); self.cols = cols; self.rows = rows; let t = transport; lock.unlock()
        t?.resize(cols: cols, rows: rows)
    }

    func disconnect() { currentTransport?.disconnect() }

    var isDisconnected: Bool { if case .disconnected = status { return true } else { return false } }

    /// Rebuild the transport and reconnect with the stored spec + last known size.
    /// SSH rebuilds the shell directly; mosh re-runs the SSH bootstrap (a fresh
    /// `mosh-server`), since a hard drop means the old UDP session is gone.
    func reconnect() {
        guard isDisconnected else { return }
        setStatus(.connecting)
        lock.lock(); let cols = self.cols, rows = self.rows; lock.unlock()
        let spec = self.spec
        Task {
            do {
                if spec.useMosh {
                    let connect = try await MoshBootstrap.connect(spec: spec)
                    let mosh = MoshSession()
                    self.wire(mosh)
                    if let err = mosh.open(host: spec.host, port: connect.port, key: connect.key, cols: cols, rows: rows) {
                        throw MoshBootstrap.Failure.noConnectLine(err)
                    }
                    self.lock.withLock { self.transport = mosh }
                } else {
                    let shell = SSHShell()
                    self.wire(shell)
                    self.lock.withLock { self.transport = shell }
                    try await shell.connect(host: spec.host, port: spec.port, user: spec.user,
                                            agent: spec.agent, cols: cols, rows: rows,
                                            knownHosts: spec.knownHosts, password: nil)
                    DispatchQueue.main.async { self.reapplyForwards() }
                }
                self.setStatus(.connected)
            } catch {
                self.setStatus(.disconnected(reason: Self.describe(error)))
            }
        }
    }

    // MARK: internals

    private var currentTransport: TerminalTransport? { lock.lock(); defer { lock.unlock() }; return transport }

    private func wire(_ transport: TerminalTransport) {
        transport.onOutput = { [weak self] bytes in self?.onOutput?(bytes) }
        transport.onClosed = { [weak self] reason in
            self?.setStatus(.disconnected(reason: reason))
        }
    }

    private func setStatus(_ s: Status) {
        DispatchQueue.main.async { self.status = s }
    }

    /// The single place that turns an error into user-facing text — used by both
    /// the reconnect banner and the Connect screen so messages stay consistent
    /// and never leak a raw `Error` description.
    static func describe(_ error: Error) -> String {
        switch error {
        case SSHShellError.connectFailed:
            return "Couldn't reach the server. Check the host, port, and your network."
        case SSHShellError.handshakeFailed:
            return "SSH handshake failed — the server may not speak SSH, or uses unsupported algorithms."
        case SSHShellError.authFailed(let m):
            return "Authentication failed: \(m)"
        case SSHShellError.hostKeyMismatch:
            return "⚠️ The host key changed — possible interception. Connection refused."
        case SSHShellError.unknownHostKey:
            return "The server's host key isn't trusted yet."
        case SSHShellError.noIdentities:
            return "No key available — add or generate a key first."
        case SSHShellError.noHostKey:
            return "The server didn't present a host key."
        case SSHShellError.channelOpenFailed, SSHShellError.ptyFailed, SSHShellError.shellFailed:
            return "Couldn't open a session on the server."
        case SSHShellError.execFailed(let m):
            return "Couldn't run the command on the server: \(m)"
        case SSHShellError.libssh2Init, SSHShellError.sessionInit:
            return "Couldn't start the SSH session."
        case SSHShellError.algorithmPolicyFailed:
            return "Couldn't enforce the secure algorithm policy — connection refused."
        case let e as LocalizedError where e.errorDescription != nil:
            return e.errorDescription!
        default:
            return "Something went wrong. Please try again."
        }
    }
}
