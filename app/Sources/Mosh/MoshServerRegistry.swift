import Foundation

/// Remembers the `mosh-server` processes we started, so the ones we abandon can
/// be shut down on the next connect instead of sitting on the host forever
/// holding a PTY (enough of them and the host can't allocate one at all).
///
/// A server becomes unreachable-but-alive whenever the client that owned it goes
/// away for good: the app was terminated in the background (iOS does that within
/// minutes), or a resume failed and `TerminalSession` re-bootstrapped. A fresh
/// client can't adopt it — it starts its crypto sequence at 0 and the server's
/// replay protection rejects it — so the only options are to reap it or leak it.
///
/// The rules are deliberately conservative: a PID is only ever *abandoned* when
/// nothing in this process can still be talking to it, and only abandoned PIDs
/// are ever signalled. That's what keeps a second live session to the same host
/// (or a session on the user's laptop) safe.
///
/// Not secret — PIDs and host names, the same class of data as `sessions.json`.
final class MoshServerRegistry: @unchecked Sendable {
    static let shared = MoshServerRegistry()

    struct Record: Codable, Equatable {
        var pid: Int32
        var hostKey: String
        /// The session that can still reach this server; nil once abandoned.
        var sessionID: UUID?
        var startedAt: Date
        /// How many connects have asked this server to quit. A reap can legitimately
        /// go unheeded — mosh-server only honours SIGUSR1 once it has been idle for
        /// `MOSH_SERVER_SIGNAL_TMOUT`, and a server we abandoned seconds ago (a
        /// failed resume, say) hasn't been — so we retry on later connects instead
        /// of giving up after one shot.
        var reapAttempts = 0
    }

    /// Records older than this are dropped unreaped: the idle timeout we launch
    /// every server with (`MOSH_SERVER_NETWORK_TMOUT`) has long since fired, and
    /// the PID has likely been recycled onto something else by now.
    private static let maxAge: TimeInterval = 7 * 24 * 3600
    private static let maxRecords = 64
    private static let maxReapAttempts = 5

    private let lock = NSLock()
    private var records: [Record] = []
    private let url: URL
    private static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mosh-servers.json")
    }

    /// `url` is injectable for tests; the app uses the shared instance.
    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? JSONDecoder().decode([Record].self, from: data) {
            records = decoded
        }
    }

    static func hostKey(host: String, port: UInt16, user: String) -> String {
        "\(user)@\(host):\(port)"
    }

    /// Called at launch: every server recorded by a previous run of the app is
    /// orphaned by definition (its client's crypto state died with the process),
    /// so mark them all reapable.
    func markAllAbandonedFromPreviousRun() {
        mutate { records in
            for i in records.indices { records[i].sessionID = nil }
        }
    }

    /// This session is about to (re-)bootstrap, or has gone away: whatever server
    /// it held can no longer be reached.
    func abandon(sessionID: UUID) {
        mutate { records in
            for i in records.indices where records[i].sessionID == sessionID {
                records[i].sessionID = nil
            }
        }
    }

    /// This particular server is unreachable now (its client tore down without
    /// the server acknowledging a shutdown). Keyed by PID rather than session so
    /// it can't race a reconnect that has already recorded a *new* server under
    /// the same session id — abandoning that one would have the next connect
    /// reap a live session.
    ///
    /// A PID only identifies a process on ONE host: two hosts hand out the same
    /// numbers independently, so the host is part of the key. Matching on the
    /// PID alone let a disconnect from one host abandon another host's live
    /// server, which the next connect there would then reap.
    func abandon(pid: Int32, hostKey: String) {
        mutate { records in
            for i in records.indices where records[i].pid == pid && records[i].hostKey == hostKey {
                records[i].sessionID = nil
            }
        }
    }

    /// The server exited cleanly (we shut it down over the mosh transport), so
    /// there's nothing left to reap. Host-scoped for the same reason as `abandon`.
    func forget(pid: Int32, hostKey: String) {
        mutate { records in records.removeAll { $0.pid == pid && $0.hostKey == hostKey } }
    }

    func record(pid: Int32, hostKey: String, sessionID: UUID) {
        mutate { records in
            records.removeAll { $0.pid == pid && $0.hostKey == hostKey }
            records.append(Record(pid: pid, hostKey: hostKey, sessionID: sessionID, startedAt: Date()))
        }
    }

    /// The abandoned PIDs on this host to ask to quit, retried across connects
    /// (see `Record.reapAttempts`) and dropped once they've had their attempts —
    /// we don't signal a PID forever, since by then it may belong to something
    /// else and the idle timeout has it covered anyway.
    func reapablePIDs(hostKey: String) -> [Int32] {
        var due: [Int32] = []
        mutate { records in
            var kept: [Record] = []
            for var r in records {
                guard r.hostKey == hostKey, r.sessionID == nil else { kept.append(r); continue }
                due.append(r.pid)
                r.reapAttempts += 1
                if r.reapAttempts < Self.maxReapAttempts { kept.append(r) }
            }
            records = kept
        }
        return due
    }

    private func mutate(_ body: (inout [Record]) -> Void) {
        lock.lock()
        body(&records)
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        records.removeAll { $0.startedAt < cutoff }
        if records.count > Self.maxRecords {
            records.removeFirst(records.count - Self.maxRecords)
        }
        // Written while still holding the lock, so the file always ends up
        // holding the newest state. Writing a snapshot after releasing it let
        // two mutations race to the disk: the older snapshot could land last and
        // erase a server recorded by the newer one — which, after a relaunch,
        // could then never be reaped. The file is a few hundred bytes; the
        // write is not worth a second ordering mechanism.
        try? JSONEncoder().encode(records).write(to: url, options: .atomic)
        lock.unlock()
    }
}
