import Foundation
import BsnsSSHCore

/// Bootstraps a mosh session the way the `mosh` wrapper does: SSH in, run
/// `mosh-server new`, and read the `MOSH CONNECT <port> <key>` line it prints.
/// The UDP session then runs to the same host on that port (see `MoshSession`).
enum MoshBootstrap {
    enum Failure: Error, LocalizedError {
        case noConnectLine(String)
        case ssh(Error)

        var errorDescription: String? {
            switch self {
            case .ssh(let e): return "couldn't start mosh-server: \(TerminalSession.describe(e))"
            case .noConnectLine(let out):
                // mosh-server missing is the common case; surface its own words if any.
                let hint = out.trimmingCharacters(in: .whitespacesAndNewlines)
                return hint.isEmpty
                    ? "the server didn't return a mosh session (is mosh-server installed?)"
                    : "mosh-server didn't start: \(hint.prefix(200))"
            }
        }
    }

    /// The command `mosh` runs on the server. `-s` binds to the SSH connection's
    /// address; `-c 256` advertises 256-color support. The locale keeps UTF-8
    /// rendering correct on the server side.
    static let serverCommand = "mosh-server new -s -c 256 -l LANG=en_US.UTF-8"

    /// SSH to `spec.host` and obtain the mosh connect parameters. `SSHShellError`
    /// (host-key, auth, …) is rethrown as-is so the caller's TOFU/auth handling
    /// applies; only the parse step gets a mosh-specific error.
    static func connect(spec: TerminalSession.Spec) async throws -> MoshConnect {
        let output: String
        do {
            output = try await SSHShell.execCapturing(
                host: spec.host, port: spec.port, user: spec.user,
                agent: spec.agent, password: nil,
                command: serverCommand, knownHosts: spec.knownHosts)
        } catch let e as SSHShellError {
            throw e
        } catch {
            throw Failure.ssh(error)
        }
        guard let connect = MoshConnect.parse(output) else {
            throw Failure.noConnectLine(output)
        }
        return connect
    }
}
