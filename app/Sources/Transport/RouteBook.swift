import Foundation
import Observation
import BsnsSSHCore

/// The other addresses each host can be reached at, and the one that answered
/// last. Consulted where sockets are opened, so every kind of connection to a
/// host — shell, side channel, file transfer, port-forward carrier, mosh
/// bootstrap — follows the same route without knowing about it. Sessions keep
/// naming the host by its primary name; that is what host-key trust is checked
/// against, whichever address was dialed.
final class RouteBook: @unchecked Sendable {
    static let shared = RouteBook()

    private let lock = NSLock()
    private var routes: [String: [String]] = [:]
    private var answered: [String: String] = [:]

    func set(_ alternates: [String], for host: String) {
        lock.withLock { routes[host.lowercased()] = alternates.isEmpty ? nil : alternates }
    }

    /// Everything to dial for `host`, preferred first.
    func candidates(for host: String) -> [String] {
        HostRoutes.candidates(primary: host, routes: lock.withLock { routes[host.lowercased()] })
    }

    func noteAnswer(from route: String, for host: String) {
        lock.withLock { answered[host.lowercased()] = route }
    }

    /// The address to use for traffic that can't race for itself (mosh's UDP):
    /// the route the last connection to this host went over.
    func address(for host: String) -> String {
        lock.withLock { answered[host.lowercased()] } ?? host
    }
}

/// Which saved machines are reachable right now, and by which address. Only
/// hosts the user gave more than one address are checked: a check is a bare
/// connection to the SSH port, closed at once, and servers on the open internet
/// shouldn't see those unasked.
@MainActor
@Observable
final class HostPresence {
    enum State: Equatable {
        case checking
        case reachable(String)
        case unreachable
    }

    private(set) var states: [UUID: State] = [:]

    func refresh(_ hosts: [SavedHost]) {
        let watched = hosts.filter { !($0.routes ?? []).isEmpty && ($0.jump ?? "").isEmpty }
        states = states.filter { id, _ in watched.contains { $0.id == id } }
        for host in watched {
            if states[host.id] == nil { states[host.id] = .checking }
            let (id, name, port) = (host.id, host.host, UInt16(clamping: host.port))
            Task.detached(priority: .utility) {
                let route = SSHShell.reachableRoute(host: name, port: port)
                await MainActor.run { self.states[id] = route.map { .reachable($0) } ?? .unreachable }
            }
        }
    }

    /// Keep the list current while a screen showing it is up.
    func watch(_ hosts: @escaping @MainActor () -> [SavedHost]) async {
        while !Task.isCancelled {
            refresh(hosts())
            try? await Task.sleep(nanoseconds: 45_000_000_000)
        }
    }
}
