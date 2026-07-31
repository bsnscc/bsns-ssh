import Foundation

/// Builds the remote command that starts (and cleans up after) `mosh-server`.
///
/// A mosh-server outlives the client by design — that's what makes mosh resume
/// across a network change. But a client that can never come back (the app was
/// terminated, or a resume failed and we re-bootstrapped) leaves it running
/// forever holding a PTY, and enough of those exhaust the host's PTYs. Nothing
/// on the client can revive such a server: a fresh client starts its crypto
/// sequence at 0 and the server's replay protection rejects it. So we make
/// abandoned servers reapable, two ways:
///
/// 1. **An idle timeout.** `MOSH_SERVER_NETWORK_TMOUT` makes mosh-server exit on
///    its own once it hasn't heard from a client for that long. It's read from
///    *mosh-server's own* environment, so it has to be an `env` prefix — mosh's
///    `-l` flag only populates the child shell's environment.
/// 2. **A targeted reap.** We remember the PID of every server we start, and the
///    next bootstrap to that host asks the ones we abandoned to shut down. The
///    signal is `SIGUSR1`, which mosh-server honours only if it has been idle at
///    least `MOSH_SERVER_SIGNAL_TMOUT` — so it can never kill a session that's
///    actually in use, including from another device.
///
/// Everything here is a pure string builder so it can be unit-tested without a
/// server; the Android bootstrap mirrors it.
public enum MoshServerCommand {
    /// How long a server we're asked to reap must have been idle before it obeys
    /// SIGUSR1. Long enough that a live-but-briefly-quiet session is never hit,
    /// short enough that reaping on the next connect actually works.
    public static let signalTimeoutSeconds = 60

    /// Default idle timeout: a day. Generous on purpose — without a multiplexer
    /// the timeout expiring loses the user's shell, and mosh's whole promise is
    /// that a session survives being away. With tmux it costs nothing (the work
    /// lives in the tmux server), so the setting can safely be lowered.
    public static let defaultIdleTimeoutSeconds = 24 * 3600

    /// The invariant part: `-s` binds to the SSH connection's address, `-c 256`
    /// advertises 256 colours. Both `LANG` and `LC_ALL` are forced to UTF-8 —
    /// `LC_ALL` overrides any inherited/forwarded `LC_CTYPE` (e.g. macOS's
    /// invalid `LC_CTYPE=UTF-8`), without which mosh-server drops to non-UTF-8
    /// mode and renders every multibyte char as `?`.
    public static let base = "mosh-server new -s -c 256 -l LANG=en_US.UTF-8 -l LC_ALL=en_US.UTF-8"

    /// The full remote command: reap what we abandoned, then start the server.
    ///
    /// - Parameters:
    ///   - tmux: optional tmux session to attach (see `tmuxSuffix`).
    ///   - idleTimeoutSeconds: `MOSH_SERVER_NETWORK_TMOUT`; 0 or less omits it
    ///     (upstream behaviour — the server never expires on its own).
    ///   - reapPIDs: servers we started earlier and can no longer reach.
    public static func build(tmux: String?,
                             idleTimeoutSeconds: Int = defaultIdleTimeoutSeconds,
                             reapPIDs: [Int32] = []) -> String {
        var env = "env"
        if idleTimeoutSeconds > 0 { env += " MOSH_SERVER_NETWORK_TMOUT=\(idleTimeoutSeconds)" }
        env += " MOSH_SERVER_SIGNAL_TMOUT=\(signalTimeoutSeconds)"
        return reapPrefix(pids: reapPIDs) + env + " " + base + tmuxSuffix(tmux)
    }

    /// `for`/`case` are POSIX-shell syntax and the remote login shell might be
    /// fish or csh, so the reaper is handed to `sh -c` — leaving only `sh`,
    /// quoting and `;` (which every shell we might land in accepts) at the top
    /// level, the same trick the tmux suffix already uses. The `ps` check keeps
    /// a recycled PID from taking an unrelated process down with it: SIGUSR1's
    /// default disposition is to terminate. PIDs are integers, so the
    /// single-quoted script needs no escaping.
    public static func reapPrefix(pids: [Int32]) -> String {
        let list = pids.filter { $0 > 1 }.map(String.init).joined(separator: " ")
        guard !list.isEmpty else { return "" }
        return "sh -c 'for p in \(list); do case \"$(ps -p \"$p\" -o comm= 2>/dev/null)\" in "
            + "*mosh-server*) kill -USR1 \"$p\" 2>/dev/null ;; esac; done' ; "
    }

    /// With a tmux session name we append a trailing command so the user lands in
    /// (and every reconnect re-attaches) a persistent `tmux new-session -A -s
    /// <name>`. If tmux isn't found it falls back to a normal login shell, so a
    /// typo or a tmux-less host never yields a dead session. Uses portable
    /// `sh -c` (no `-l`: /bin/sh is often dash, which lacks a login flag); `-l`
    /// is applied only to the fallback `$SHELL` (bash/zsh, where it's supported).
    public static func tmuxSuffix(_ tmux: String?) -> String {
        guard let name = sanitizedTmuxName(tmux) else { return "" }
        return " -- sh -c 'tmux new-session -A -s \(name) || exec ${SHELL:-/bin/sh} -l'"
    }

    /// tmux session names can't contain `.` or `:`; restrict to a conservative
    /// shell-safe set so the command is injection-proof and tmux-legal. Empty
    /// after filtering ⇒ no tmux.
    public static func sanitizedTmuxName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        let cleaned = String(raw.filter { allowed.contains($0) })
        return cleaned.isEmpty ? nil : cleaned
    }
}
