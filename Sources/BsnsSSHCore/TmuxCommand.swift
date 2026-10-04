import Foundation

/// Builds the remote commands the app runs against tmux over a side SSH
/// connection: read a pane's history, list a session's windows, switch window.
///
/// Like `MoshServerCommand`, everything here is a pure string builder so it can
/// be unit-tested without a server. Each command is one `sh -c '…'` — the
/// remote login shell might be fish or csh, and a single-quoted POSIX script is
/// the one form they all pass through untouched. For that to hold the script
/// itself must never contain a single quote; `script(_:)` enforces it.
public enum TmuxCommand {
    /// Which tmux client is "this terminal". The commands act on whatever that
    /// client is looking at.
    public struct Target: Equatable, Sendable {
        /// The session name, when the app started tmux itself and so knows it.
        public var session: String?
        /// The PID of this terminal's mosh-server. tmux runs somewhere beneath
        /// it, so the client whose ancestry includes this PID is ours.
        public var moshServerPID: Int32?

        public init(session: String? = nil, moshServerPID: Int32? = nil) {
            self.session = MoshServerCommand.sanitizedTmuxName(session)
            self.moshServerPID = moshServerPID.flatMap { $0 > 1 ? $0 : nil }
        }
    }

    /// Hard ceiling on a history request, so a typo can't ask for gigabytes.
    public static let maxHistoryLines = 50_000

    /// Separates the fields of a `listWindows` row. Printable ASCII on purpose:
    /// tmux replaces control characters in what it prints with `_`. A window
    /// name can contain anything, including this, so the parser takes the fixed
    /// fields from both ends and lets the name keep whatever is in the middle.
    public static let fieldSeparator = "~|~"

    /// `tmux`, forced to UTF-8. An SSH exec session usually has no locale set,
    /// and without one tmux prints every non-ASCII character as `_`.
    static let tmux = "tmux -u"

    /// Wrap a POSIX script for the remote login shell. Non-interactive SSH
    /// sessions often get a bare PATH, so the usual package-manager locations are
    /// appended — the same reason a login shell is needed to find `mosh-server`.
    public static func script(_ body: String) -> String {
        precondition(!body.contains("'"), "tmux scripts are single-quoted; they cannot contain a quote")
        return "sh -c 'PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin\"; " + body + "'"
    }

    /// Sets `$s` (session) and `$p` (active pane) for the target.
    ///
    /// With a known session name both follow from it. Otherwise the client has
    /// to be found: first by ancestry (the mosh-server PID), and failing that by
    /// taking the client that was used most recently — the user just touched
    /// this terminal to ask, so that is nearly always the right one.
    static func resolve(_ target: Target) -> String {
        if let name = target.session {
            return "s=\"=\(name)\"; p=\"=\(name):\"; "
        }
        var script = "c=\"\"; "
        if let pid = target.moshServerPID {
            script += "for l in $(\(tmux) list-clients -F \"#{client_pid}:#{client_tty}\" 2>/dev/null); do "
                + "a=${l%%:*}; n=0; "
                + "while [ \"$a\" -gt 1 ] 2>/dev/null && [ $n -lt 12 ]; do "
                + "if [ \"$a\" = \"\(pid)\" ]; then c=${l#*:}; fi; "
                + "a=$(ps -o ppid= -p \"$a\" 2>/dev/null | tr -d \" \"); n=$((n+1)); "
                + "done; done; "
        }
        script += "[ -n \"$c\" ] || c=$(\(tmux) list-clients -F \"#{client_activity} #{client_tty}\" 2>/dev/null "
            + "| sort -rn | head -1 | cut -d\" \" -f2); "
            + "[ -n \"$c\" ] || { echo \"no tmux client is attached\" >&2; exit 3; }; "
            + "s=$(\(tmux) display-message -p -c \"$c\" \"#{session_id}\"); "
            + "p=$(\(tmux) display-message -p -c \"$c\" \"#{pane_id}\"); "
        return script
    }

    /// The active pane's history plus its visible screen, as plain text with
    /// wrapped lines joined (`-J`), so a long line copies as one line. The first
    /// line of the output is the pane's width in columns (see `parseHistory`).
    public static func captureHistory(_ target: Target, lines: Int) -> String {
        let count = min(max(lines, 1), maxHistoryLines)
        return script(resolve(target)
            + "\(tmux) display-message -p -t \"$p\" \"#{pane_width}\"; "
            + "\(tmux) capture-pane -p -J -S -\(count) -t \"$p\"")
    }

    /// Split `captureHistory` output into the pane width and the text. The width
    /// matters for reading the text back: a shell's line editor wraps a long
    /// command by moving to the next row itself, which tmux can't tell from two
    /// separate lines — but such a row is exactly as wide as the pane.
    public static func parseHistory(_ output: String) -> (width: Int?, text: String) {
        guard let newline = output.firstIndex(where: \.isNewline) else { return (nil, output) }
        let first = output[..<newline]
        guard !first.isEmpty, first.allSatisfy(\.isASCII), let width = Int(first), width > 0 else { return (nil, output) }
        return (width, String(output[output.index(after: newline)...]))
    }

    /// One row per window: index, active flag (1/0), name, and the command
    /// running in its active pane, separated by `fieldSeparator`.
    public static func listWindows(_ target: Target) -> String {
        let f = fieldSeparator
        return script(resolve(target)
            + "\(tmux) list-windows -t \"$s\" -F \"#{window_index}\(f)#{window_active}\(f)#{window_name}\(f)#{pane_current_command}\"")
    }

    public static func selectWindow(_ target: Target, index: Int) -> String {
        script(resolve(target) + "\(tmux) select-window -t \"$s:\(max(0, index))\"")
    }

    public static func newWindow(_ target: Target) -> String {
        script(resolve(target) + "\(tmux) new-window -t \"$s:\"")
    }

    /// A window as reported by `listWindows`.
    public struct Window: Equatable, Identifiable, Sendable {
        public let index: Int
        public let isActive: Bool
        public let name: String
        public let command: String
        public var id: Int { index }
    }

    /// Parse `listWindows` output. Rows that don't have the expected shape (a
    /// login banner printed ahead of the listing, say) are skipped.
    public static func parseWindows(_ output: String) -> [Window] {
        output.split(whereSeparator: \.isNewline).compactMap { row in
            let fields = row.components(separatedBy: fieldSeparator)
            guard fields.count >= 4, let index = Int(fields[0]), fields[1] == "0" || fields[1] == "1" else { return nil }
            let name = fields[2..<(fields.count - 1)].joined(separator: fieldSeparator)
            return Window(index: index, isActive: fields[1] == "1", name: name, command: fields[fields.count - 1])
        }
    }
}
