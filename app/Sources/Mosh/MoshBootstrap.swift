import Foundation
import BsnsSSHCore

/// Bootstraps a mosh session the way the `mosh` wrapper does: SSH in, run
/// `mosh-server new`, and read the `MOSH CONNECT <port> <key>` line it prints.
/// The UDP session then runs to the same host on that port (see `MoshSession`).
/// The remote command (built in the core as `MoshServerCommand`, mirrored by the
/// Android bootstrap) reaps the servers this device abandoned on that host, then
/// starts a new one with an idle timeout so anything the reap misses still
/// expires by itself.
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

    /// Re-exported for the connect form, which sanitizes the tmux name the same
    /// way before saving it on the host.
    static func sanitizedTmuxName(_ raw: String?) -> String? {
        MoshServerCommand.sanitizedTmuxName(raw)
    }

    /// The user's `MOSH_SERVER_NETWORK_TMOUT`, in seconds (0 = never expire).
    static var idleTimeoutSeconds: Int {
        let hours = UserDefaults.standard.integer(forKey: SettingsKey.moshIdleTimeoutHours)
        return max(0, hours) * 3600
    }

    /// Whether to set tmux up so its copies reach this device (see
    /// `MoshServerCommand.tmuxSuffix`). Pointless unless the app also honours
    /// remote clipboard writes, so it follows that switch as well as its own.
    static var tmuxClipboardSetup: Bool {
        let d = UserDefaults.standard
        return d.bool(forKey: SettingsKey.remoteClipboard) && d.bool(forKey: SettingsKey.tmuxClipboard)
    }

    /// SSH to `spec.host` and obtain the mosh connect parameters. `SSHShellError`
    /// (host-key, auth, …) is rethrown as-is so the caller's TOFU/auth handling
    /// applies; only the parse step gets a mosh-specific error.
    ///
    /// `sessionID` ties the server we're about to start to the session that owns
    /// it. Re-bootstrapping the same session first abandons its previous server:
    /// mosh state is server-side, but a *new* client can't resume an old server
    /// (replay protection rejects a sequence that restarts at 0), so that one is
    /// unreachable from here on and should be reaped rather than leaked.
    static func connect(spec: TerminalSession.Spec, sessionID: UUID) async throws -> MoshConnect {
        let registry = MoshServerRegistry.shared
        let hostKey = MoshServerRegistry.hostKey(host: spec.host, port: spec.port, user: spec.user)
        registry.abandon(sessionID: sessionID)
        let reap = registry.reapablePIDs(hostKey: hostKey)
        if !reap.isEmpty { DiagLog.log("mosh", "reaping abandoned mosh-server pids \(reap) on \(hostKey)") }
        let command = MoshServerCommand.build(tmux: spec.tmuxSession,
                                              idleTimeoutSeconds: idleTimeoutSeconds,
                                              reapPIDs: reap,
                                              tmuxClipboard: tmuxClipboardSetup,
                                              tmuxDirectory: spec.tmuxDirectory)
        let output: String
        do {
            output = try await SSHShell.execCapturing(
                host: spec.host, port: spec.port, user: spec.user,
                agent: spec.agent, password: nil,
                command: command, knownHosts: spec.knownHosts, keyBlob: spec.keyBlob,
                // The detached PID we need for the next reap is printed on stderr.
                includeStderr: true)
        } catch let e as SSHShellError {
            throw e
        } catch {
            throw Failure.ssh(error)
        }
        guard let connect = MoshConnect.parse(output) else {
            throw Failure.noConnectLine(output)
        }
        if let pid = connect.pid {
            registry.record(pid: pid, hostKey: hostKey, sessionID: sessionID)
            DiagLog.log("mosh", "mosh-server pid \(pid) on \(hostKey)")
        }
        return connect
    }
}
