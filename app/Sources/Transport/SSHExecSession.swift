import Foundation
import Dispatch
import CSSH
import BsnsSSHCore

/// An authenticated SSH connection kept open to run several short commands.
///
/// `SSHShell.execCapturing` connects, authenticates, runs one command and hangs
/// up — fine for a single bootstrap, but a panel that lists tmux windows, then
/// switches one, then reads a pane's history would pay a handshake and an agent
/// signature (a biometric prompt, for a hardware-backed key) every time. This
/// keeps the session for as long as the panel is open: one signature, then each
/// command is just a channel.
///
/// Like every libssh2 session it is single-threaded, so all work is confined to
/// one serial queue.
final class SSHExecSession: @unchecked Sendable {
    /// Room for a long pane history; the one-shot exec's cap is sized for a
    /// `MOSH CONNECT` line and a login banner.
    static let historyStreamCap = 8 * 1024 * 1024

    private let queue = DispatchQueue(label: "cc.bsns.ssh.exec")
    private var fd: Int32 = -1              // queue-only
    private var session: OpaquePointer?     // queue-only

    func connect(host: String, port: UInt16, user: String, agent: Agent,
                 knownHosts: KnownHosts, keyBlob: Data?) async throws {
        let identities = SSHShell.restrict(await agent.identities(), to: keyBlob)
        guard !identities.isEmpty else { throw SSHShellError.noIdentities }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let opened = try SSHShell.openAuthenticatedSession(
                        host: host, port: port, user: user, agent: agent, identities: identities,
                        password: nil, knownHosts: knownHosts)
                    self.fd = opened.fd
                    self.session = opened.session
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Run `command` to completion. Throws if the connection has gone away.
    func run(_ command: String, streamCap: Int = SSHShell.execStreamCap) async throws -> SSHShell.ExecResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SSHShell.ExecResult, Error>) in
            queue.async {
                guard let session = self.session else {
                    cont.resume(throwing: SSHShellError.connectFailed)
                    return
                }
                do {
                    cont.resume(returning: try SSHShell.exec(command, on: session, fd: self.fd, streamCap: streamCap))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        queue.async {
            if let session = self.session {
                libssh2_session_set_blocking(session, 1)
                libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "done", "")
                libssh2_session_free(session)
                self.session = nil
            }
            if self.fd >= 0 { Darwin.close(self.fd); self.fd = -1 }
        }
    }
}
