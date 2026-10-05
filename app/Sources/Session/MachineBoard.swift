import Foundation
import Observation
import BsnsSSHCore

/// What is running in tmux on each of the user's machines, and which of it is
/// waiting for them.
///
/// A remote machine is watched over one side connection that stays open: the
/// key signs once, when watching starts, and every refresh after that is just
/// a command on the same connection. This Mac is read directly. Nothing is
/// installed on the other side — the listing is one `tmux` command.
@MainActor
@Observable
final class MachineBoard {
    struct Machine: Identifiable {
        enum State: Equatable { case idle, connecting, live, failed(String) }
        let id: String
        var name: String
        /// nil for the machine the app is running on.
        var host: SavedHost?
        var state: State = .idle
        var overview: TmuxOverview?
        var tracker = AttentionTracker()

        var isLocal: Bool { host == nil }
        func attention(for window: TmuxOverview.Window) -> AttentionTracker.State {
            tracker.state(of: window, now: overview?.now ?? 0)
        }
    }

    static let localID = "local"
    private(set) var machines: [Machine] = []
    /// A window started waiting (work stopped, or it rang the bell).
    @ObservationIgnored var onAttention: ((Machine, TmuxOverview.Window) -> Void)?

    @ObservationIgnored private var channels: [String: SSHExecSession] = [:]
    @ObservationIgnored private var polls: [String: Task<Void, Never>] = [:]
    private static let interval: UInt64 = 3_000_000_000

    var waitingCount: Int { machines.reduce(0) { $0 + $1.tracker.waitingCount } }

    /// Rebuild the list from the saved hosts, keeping what is already known
    /// about each. Hosts reached through a jump host are left out (a side
    /// connection has no tunnel for them yet).
    func sync(hosts: [SavedHost], localName: String?) {
        var next: [Machine] = []
        if let localName {
            next.append(machines.first { $0.id == Self.localID } ?? Machine(id: Self.localID, name: localName, host: nil))
        }
        for host in hosts where (host.jump ?? "").isEmpty {
            let id = host.id.uuidString
            var machine = machines.first { $0.id == id } ?? Machine(id: id, name: "", host: host)
            machine.host = host
            machine.name = host.label.isEmpty ? host.host : host.label
            next.append(machine)
        }
        for gone in machines where !next.contains(where: { $0.id == gone.id }) { stop(gone.id) }
        machines = next
    }

    /// Start watching a remote machine. Signs once, with `keyBlob` if given.
    func watch(_ id: String, agent: Agent, knownHosts: KnownHosts, keyBlob: Data?) {
        guard let machine = machines.first(where: { $0.id == id }), let host = machine.host,
              polls[id] == nil, machine.state != .connecting else { return }
        update(id) { $0.state = .connecting }
        polls[id] = Task { [weak self] in
            let channel = SSHExecSession()
            do {
                try await channel.connect(host: host.host, port: UInt16(clamping: host.port), user: host.user,
                                          agent: agent, knownHosts: knownHosts, keyBlob: keyBlob)
            } catch {
                self?.finish(id, failure: TerminalSession.describe(error))
                return
            }
            guard let self, !Task.isCancelled else { channel.close(); return }
            self.channels[id] = channel
            await self.poll(id) {
                let result = try await withLinkTimeout(10) { try await channel.run(TmuxCommand.overview()) }
                return result.stdoutString
            }
        }
    }

    #if os(macOS)
    /// Watch the machine the app is running on. No connection, no signature.
    func watchLocal() {
        let id = Self.localID
        guard machines.contains(where: { $0.id == id }), polls[id] == nil else { return }
        polls[id] = Task { [weak self] in
            await self?.poll(id) { try await Self.runLocally(TmuxCommand.overview()) }
        }
    }

    /// Run one of the `sh -c '…'` commands on this Mac, with a deadline.
    nonisolated static func runLocally(_ command: String) async throws -> String {
        try await withLinkTimeout(6) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                process.terminationHandler = { _ in
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        }
    }
    #endif

    func stop(_ id: String) {
        polls[id]?.cancel()
        polls[id] = nil
        channels[id]?.close()
        channels[id] = nil
        update(id) { $0.state = .idle; $0.overview = nil; $0.tracker = AttentionTracker() }
    }

    /// The user is looking at this window now.
    func acknowledge(machine id: String, window: String) {
        update(id) { $0.tracker.acknowledge(window) }
    }

    /// Make `index` the current window of `session` on that machine.
    func selectWindow(machine id: String, session: String, index: Int) async {
        let command = TmuxCommand.selectWindow(.init(session: session), index: index)
        if let channel = channels[id] {
            _ = try? await withLinkTimeout(6) { try await channel.run(command) }
        } else if id == Self.localID {
            #if os(macOS)
            _ = try? await Self.runLocally(command)
            #endif
        }
    }

    // MARK: internals

    private func poll(_ id: String, fetch: @escaping @Sendable () async throws -> String) async {
        while !Task.isCancelled {
            do {
                let output = try await fetch()
                guard !Task.isCancelled else { return }
                guard let overview = TmuxCommand.parseOverview(output) else {
                    throw LinkConnection.TransportError.closed
                }
                var started: [TmuxOverview.Window] = []
                update(id) {
                    $0.state = .live
                    $0.overview = overview
                    started = $0.tracker.feed(overview)
                }
                if let machine = machines.first(where: { $0.id == id }) {
                    for window in started { onAttention?(machine, window) }
                }
            } catch {
                if !Task.isCancelled { finish(id, failure: TerminalSession.describe(error)) }
                return
            }
            try? await Task.sleep(nanoseconds: Self.interval)
        }
    }

    private func finish(_ id: String, failure: String) {
        polls[id] = nil
        channels[id]?.close()
        channels[id] = nil
        update(id) { $0.state = .failed(failure); $0.overview = nil }
    }

    private func update(_ id: String, _ change: (inout Machine) -> Void) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        change(&machines[index])
    }

    /// "12s", "4m", "3h", "2d".
    static func span(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}
