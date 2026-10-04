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
    ///   - tmuxClipboard: also make tmux's copies reach the client (see
    ///     `tmuxSuffix`). Off by default — it changes an option on the user's
    ///     tmux server.
    public static func build(tmux: String?,
                             idleTimeoutSeconds: Int = defaultIdleTimeoutSeconds,
                             reapPIDs: [Int32] = [],
                             tmuxClipboard: Bool = false) -> String {
        var env = "env"
        if idleTimeoutSeconds > 0 { env += " MOSH_SERVER_NETWORK_TMOUT=\(idleTimeoutSeconds)" }
        env += " MOSH_SERVER_SIGNAL_TMOUT=\(signalTimeoutSeconds)"
        return reapPrefix(pids: reapPIDs) + env + " " + base + tmuxSuffix(tmux, clipboard: tmuxClipboard)
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
    ///
    /// With `clipboard`, tmux is also told how to address the clipboard. When
    /// tmux copies, it writes to the terminal's clipboard with the target field
    /// left empty (`OSC 52 ; ; <data>`), and mosh-server only relays a write that
    /// names the clipboard (`OSC 52 ; c ; <data>`) — so over mosh a tmux copy
    /// never arrives. The fix is a `terminal-overrides` entry that makes tmux emit
    /// the `c`. It has to be in place before this client attaches (overrides are
    /// read when a client's terminal is opened), hence `start-server` and the
    /// `set` in the same command as `new-session`; and it is skipped when an
    /// entry is already there, so reconnecting doesn't pile up duplicates.
    public static func tmuxSuffix(_ tmux: String?, clipboard: Bool = false) -> String {
        guard let name = sanitizedTmuxName(tmux) else { return "" }
        let attach = "tmux new-session -A -s \(name)"
        guard clipboard else { return " -- sh -c '\(attach) || exec ${SHELL:-/bin/sh} -l'" }
        return " -- sh -c 'if tmux show -s terminal-overrides 2>/dev/null | grep -q \"\(clipboardOverrideMarker)\"; "
            + "then \(attach); "
            + "else tmux start-server \\; set -as terminal-overrides \"\(clipboardOverride)\" \\; "
            + "new-session -A -s \(name); fi || exec ${SHELL:-/bin/sh} -l'"
    }

    /// The `terminal-overrides` entry, as it must appear inside double quotes in
    /// a POSIX script (hence the doubled backslashes: tmux has to receive `\E`
    /// and `\007` literally and decode them itself). The capability consumes its
    /// first parameter with a zero-width format (`%p1%.0s`) on purpose — current
    /// tmux refuses a clipboard capability that ignores a parameter and then
    /// emits nothing at all.
    static let clipboardOverride = ",xterm*:Ms=\\\\E]52;c%p1%.0s;%p2%s\\\\007"
    /// Enough of the entry to recognise it in `tmux show` output.
    static let clipboardOverrideMarker = "52;c%p1"

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
