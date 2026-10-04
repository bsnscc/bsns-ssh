import Foundation
import AppKit
import Observation
import BsnsSSHCore

/// What each key has been used for: which program asked, to sign in where, and
/// whether it went through. Kept on this Mac only, in a small file next to the
/// app's other state; it never records what was signed.
@MainActor
@Observable
final class KeyActivityLog {
    static let shared = KeyActivityLog()
    private static let limit = 1000

    private(set) var events: [AgentAuditEvent] = []
    @ObservationIgnored private let url: URL = {
        let dir = AppPaths.support
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("key-activity.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([AgentAuditEvent].self, from: data) {
            events = decoded
        }
    }

    /// Callable from any thread — the agent reports from wherever it signed.
    nonisolated func record(_ event: AgentAuditEvent) {
        Task { @MainActor in
            self.events.append(event)
            if self.events.count > Self.limit { self.events.removeFirst(self.events.count - Self.limit) }
            self.save()
        }
    }

    func clear() {
        events = []
        save()
    }

    private func save() {
        try? JSONEncoder().encode(events).write(to: url, options: .atomic)
    }
}

/// Runs the agent socket according to the user's settings.
@MainActor
@Observable
final class AgentSocketController {
    static let enabledKey = "agent.socketEnabled"
    static let hardwareOnlyKey = "agent.socketHardwareOnly"

    enum State: Equatable { case off, listening, failed(String) }
    private(set) var state = State.off

    @ObservationIgnored private var server: AgentSocketServer?
    /// Set by the debug hook: this run's socket was started explicitly and the
    /// saved settings must not override it.
    @ObservationIgnored var pinned = false

    init() {
        // Take the socket file away on a normal quit, so nothing is left
        // pointing at an agent that isn't there. (After a crash the stale file
        // is removed when the socket next starts.)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.server?.stop() }
        }
    }

    static func registerDefaults() {
        // Off until asked for; and when on, only keys that ask every time are
        // offered unless the user widens it.
        UserDefaults.standard.register(defaults: [enabledKey: false, hardwareOnlyKey: true])
    }

    /// Apply the current settings: (re)start or stop the socket.
    func apply(agent: Agent, knownHosts: KnownHosts) {
        guard !pinned else { return }
        let defaults = UserDefaults.standard
        start(enabled: defaults.bool(forKey: Self.enabledKey),
              hardwareOnly: defaults.bool(forKey: Self.hardwareOnlyKey), agent: agent, knownHosts: knownHosts)
    }

    func start(enabled: Bool, hardwareOnly: Bool, agent: Agent, knownHosts: KnownHosts) {
        server?.stop()
        server = nil
        guard enabled else { state = .off; return }
        // Names for host keys the app has seen, so a prompt can say where a
        // key is being used ("user@host:22" → host).
        var names: [Data: String] = [:]
        for (identifier, key) in knownHosts.allEntries { names[key.blob] = identifier }
        let lookup = names
        let presenceOnly: @Sendable (any KeyBackend) -> Bool = { $0.requiresUserPresence }
        let server = AgentSocketServer(agent: agent, exposing: hardwareOnly ? presenceOnly : nil,
                                       hostName: { blob in lookup[blob] })
        do {
            try server.start()
            self.server = server
            state = .listening
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        server?.stop()
        server = nil
        state = .off
    }
}
