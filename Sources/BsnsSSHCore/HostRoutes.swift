import Foundation

/// One machine, several addresses: a LAN name at home, a tailnet name away.
/// The host a session is *named* by stays the same — it is what host-key trust
/// and saved state hang on — while the address actually dialed is whichever
/// route answers.
public enum HostRoutes {
    public static let maxRoutes = 6

    /// Addresses typed as a list ("studio.local, studio.tailnet.example"),
    /// without the primary, duplicates, or anything that isn't an address.
    public static func parse(_ text: String, excluding primary: String) -> [String] {
        var seen: Set<String> = [primary.lowercased()]
        var routes: [String] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
            let route = String(piece)
            guard isAddress(route), seen.insert(route.lowercased()).inserted else { continue }
            routes.append(route)
            if routes.count == maxRoutes { break }
        }
        return routes
    }

    /// Everything to dial for a host, in order of preference.
    public static func candidates(primary: String, routes: [String]?) -> [String] {
        [primary] + parse((routes ?? []).joined(separator: " "), excluding: primary)
    }

    /// A DNS name or an IPv4 / IPv6 literal — not a URL, a user@host, or a path.
    static func isAddress(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 253 && text.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "." || $0 == "-" || $0 == "_" || $0 == ":" || $0 == "%"
        }
    }
}

/// Dials several routes at once and keeps the first that answers.
///
/// Routes are started in order, a beat apart, so the preferred one wins when
/// both are up; a route that fails outright lets the next start immediately,
/// and one that hangs (a LAN name looked up from somewhere else) doesn't hold
/// the others back. Blocking — call it off the main thread.
public enum RouteRace {
    public static func first<T: Sendable>(_ candidates: [String], stagger: TimeInterval = 0.3,
                                          connect: @escaping @Sendable (String) -> T?,
                                          discard: @escaping @Sendable (T) -> Void) -> (route: String, value: T)? {
        guard candidates.count > 1 else {
            guard let only = candidates.first, let value = connect(only) else { return nil }
            return (only, value)
        }
        let state = RaceState<T>()
        var launched = 0
        for route in candidates {
            launched += 1
            let thread = Thread {
                let value = connect(route)
                if let loser = state.finish(route: route, value: value) { discard(loser) }
            }
            thread.stackSize = 512 * 1024
            thread.start()
            if state.waitBeforeNext(launched: launched, timeout: stagger) { break }
        }
        return state.waitForResult(launched: launched)
    }
}

private final class RaceState<T: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var winner: (route: String, value: T)?
    private var finished = 0

    /// Record one attempt's outcome. Returns the value to throw away when
    /// another route already won.
    func finish(route: String, value: T?) -> T? {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        finished += 1
        guard let value else { return nil }
        if winner == nil {
            winner = (route, value)
            return nil
        }
        return value
    }

    /// Hold off starting the next route until the stagger passes or every
    /// attempt so far has failed. True when a route has already won.
    func waitBeforeNext(launched: Int, timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while winner == nil && finished < launched {
            if !condition.wait(until: deadline) { break }
        }
        return winner != nil
    }

    func waitForResult(launched: Int) -> (route: String, value: T)? {
        condition.lock()
        defer { condition.unlock() }
        while winner == nil && finished < launched { condition.wait() }
        return winner
    }
}
