import Foundation

/// Everything running in tmux on one machine, plus how busy the machine is —
/// what a "which of my machines is doing what" view needs, from one command.
public struct TmuxOverview: Equatable, Sendable {
    public struct Window: Equatable, Identifiable, Sendable {
        public let session: String
        public let index: Int
        public let isActive: Bool
        /// tmux's bell flag: something in the window rang the bell while it
        /// wasn't being looked at.
        public let bell: Bool
        /// When the window last produced output, in the machine's own clock.
        public let lastActivity: Int
        /// How many clients are attached to the window's session.
        public let attached: Int
        public let name: String
        public let command: String
        public var id: String { "\(session):\(index)" }
    }

    /// The machine's clock when the listing was taken (seconds since 1970), so
    /// "quiet for" never depends on two machines agreeing on the time.
    public var now: Int
    public var windows: [Window]
    /// 1-, 5- and 15-minute load averages, when the machine reports them.
    public var load: [Double]
    public var cpus: Int?

    public var sessions: [String] {
        var seen = Set<String>()
        return windows.map(\.session).filter { seen.insert($0).inserted }
    }
}

extension TmuxCommand {
    /// One row per window across every session, then the machine's clock, load
    /// and CPU count. A machine with no tmux server (or no tmux) still answers
    /// with the last three, so "nothing running" and "unreachable" stay distinct.
    public static func overview() -> String {
        let f = fieldSeparator
        return script(
            "\(tmux) list-windows -a -F \"w\(f)#{session_name}\(f)#{window_index}\(f)#{window_active}\(f)#{window_bell_flag}"
            + "\(f)#{window_activity}\(f)#{session_attached}\(f)#{window_name}\(f)#{pane_current_command}\" 2>/dev/null; "
            + "echo \"now\(f)$(date +%s)\"; "
            + "echo \"load\(f)$( (sysctl -n vm.loadavg 2>/dev/null || cat /proc/loadavg 2>/dev/null) | tr -d \"{}\")\"; "
            + "echo \"cpus\(f)$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null)\"")
    }

    /// Parse `overview` output; nil when the clock line is missing, which means
    /// the command didn't run to the end. Rows of any other shape are skipped.
    public static func parseOverview(_ output: String) -> TmuxOverview? {
        var now: Int?
        var windows: [TmuxOverview.Window] = []
        var load: [Double] = []
        var cpus: Int?
        for row in output.split(whereSeparator: \.isNewline) {
            let fields = row.components(separatedBy: fieldSeparator)
            switch fields.first {
            case "now" where fields.count == 2:
                now = Int(fields[1].trimmingCharacters(in: .whitespaces))
            case "load" where fields.count == 2:
                load = fields[1].split(separator: " ").prefix(3).compactMap { Double($0) }
            case "cpus" where fields.count == 2:
                cpus = Int(fields[1].trimmingCharacters(in: .whitespaces))
            case "w" where fields.count >= 9:
                // The window name is the one free-text field in the middle; the
                // fixed fields are taken from both ends around it.
                guard let index = Int(fields[2]), fields[3] == "0" || fields[3] == "1",
                      fields[4] == "0" || fields[4] == "1", let activity = Int(fields[5]),
                      let attached = Int(fields[6]), !fields[1].isEmpty else { continue }
                windows.append(.init(session: fields[1], index: index, isActive: fields[3] == "1",
                                     bell: fields[4] == "1", lastActivity: activity, attached: attached,
                                     name: fields[7..<(fields.count - 1)].joined(separator: fieldSeparator),
                                     command: fields[fields.count - 1]))
            default:
                continue
            }
        }
        guard let now else { return nil }
        return TmuxOverview(now: now, windows: windows, load: load, cpus: cpus)
    }
}

/// Decides which windows want their owner: ones that worked for a while and
/// then went quiet (a build finished, an agent stopped to ask something), and
/// ones that rang the bell. Fed one overview at a time; pure, so the rules can
/// be tested without a machine.
public struct AttentionTracker: Sendable {
    public enum State: Equatable, Sendable {
        /// Producing output right now.
        case working
        /// Worked, then stopped — or rang the bell — and hasn't been looked at.
        case waiting(since: Int)
        case quiet
    }

    /// Output within this many seconds counts as "right now".
    public var busyWindow = 5
    /// A run of output at least this long is work worth announcing when it ends…
    public var minimumRun = 8
    /// …once it has been quiet this long.
    public var settle = 6

    private struct Track: Sendable {
        var lastActivity: Int
        var runStart: Int?
        var waitingSince: Int?
        var bell: Bool
    }
    private var tracks: [String: Track] = [:]
    private var primed = false

    public init() {}

    /// Take in a fresh overview. Returns the windows that started waiting just
    /// now — each is reported once.
    public mutating func feed(_ overview: TmuxOverview) -> [TmuxOverview.Window] {
        var started: [TmuxOverview.Window] = []
        var next: [String: Track] = [:]
        for window in overview.windows {
            var track = tracks[window.id] ?? Track(lastActivity: window.lastActivity, runStart: nil, waitingSince: nil, bell: window.bell)
            let known = tracks[window.id] != nil
            if known, window.lastActivity > track.lastActivity {
                // New output: a run begins or continues, and any wait is over.
                if track.runStart == nil { track.runStart = track.lastActivity > 0 && overview.now - track.lastActivity <= busyWindow ? track.lastActivity : window.lastActivity }
                track.lastActivity = window.lastActivity
                track.waitingSince = nil
            }
            let quietFor = overview.now - track.lastActivity
            if let runStart = track.runStart, quietFor >= settle {
                if track.lastActivity - runStart >= minimumRun, track.waitingSince == nil {
                    track.waitingSince = track.lastActivity
                    started.append(window)
                }
                track.runStart = nil
            }
            if window.bell, !track.bell, known, track.waitingSince == nil {
                track.waitingSince = overview.now
                started.append(window)
            }
            track.bell = window.bell
            next[window.id] = track
        }
        tracks = next
        // The first look only sets the baseline: nothing is "newly" waiting.
        defer { primed = true }
        return primed ? started : []
    }

    public func state(of window: TmuxOverview.Window, now: Int) -> State {
        guard let track = tracks[window.id] else { return .quiet }
        if let since = track.waitingSince { return .waiting(since: since) }
        return now - track.lastActivity <= busyWindow ? .working : .quiet
    }

    /// The user has looked at this window; it stops waiting.
    public mutating func acknowledge(_ id: String) {
        tracks[id]?.waitingSince = nil
    }

    public var waitingCount: Int { tracks.values.filter { $0.waitingSince != nil }.count }
}
