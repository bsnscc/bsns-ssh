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
    /// address; `-c 256` advertises 256-color support. Both `LANG` and `LC_ALL`
    /// are forced to UTF-8: `LC_ALL` overrides any inherited/forwarded `LC_CTYPE`
    /// (e.g. macOS's invalid `LC_CTYPE=UTF-8`), without which mosh-server drops to
    /// non-UTF-8 mode and renders every multibyte char (smart quotes, dashes,
    /// spinner glyphs) as `?`. Mirrors the Android bootstrap.
    static let serverCommandBase = "mosh-server new -s -c 256 -l LANG=en_US.UTF-8 -l LC_ALL=en_US.UTF-8"

    /// The remote command to launch. With a tmux session name we append a trailing
    /// command so the user lands in (and every reconnect re-attaches) a persistent
    /// `tmux new-session -A -s <name>`. If tmux isn't found it falls back to a normal
    /// login shell, so a typo or a tmux-less host never yields a dead session. Uses
    /// portable `sh -c` (no `-l`: /bin/sh is often dash, which lacks a login flag);
    /// `-l` is applied only to the fallback `$SHELL` (bash/zsh, where it's supported).
    /// The name is sanitized to a shell-safe charset, so the single-quoted command
    /// needs no further escaping.
    static func serverCommand(tmux: String?) -> String {
        guard let name = sanitizedTmuxName(tmux) else { return serverCommandBase }
        return serverCommandBase
            + " -- sh -c 'tmux new-session -A -s \(name) || exec ${SHELL:-/bin/sh} -l'"
    }

    /// tmux session names can't contain `.` or `:`; restrict to a conservative
    /// shell-safe set so the command is injection-proof and tmux-legal. Empty after
    /// filtering ⇒ no tmux.
    static func sanitizedTmuxName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        let cleaned = String(raw.filter { allowed.contains($0) })
        return cleaned.isEmpty ? nil : cleaned
    }

    /// SSH to `spec.host` and obtain the mosh connect parameters. `SSHShellError`
    /// (host-key, auth, …) is rethrown as-is so the caller's TOFU/auth handling
    /// applies; only the parse step gets a mosh-specific error.
    static func connect(spec: TerminalSession.Spec) async throws -> MoshConnect {
        let output: String
        do {
            output = try await SSHShell.execCapturing(
                host: spec.host, port: spec.port, user: spec.user,
                agent: spec.agent, password: nil,
                command: serverCommand(tmux: spec.tmuxSession), knownHosts: spec.knownHosts, keyBlob: spec.keyBlob)
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
