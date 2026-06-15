import Foundation
import Observation
import BsnsSSHCore

/// A saved connection target.
struct SavedHost: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var host: String
    var port: Int
    var user: String
}

private func appSupportURL(_ name: String) -> URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

/// Saved hosts, persisted to a JSON file (host configs aren't secret).
@MainActor
@Observable
final class HostStore {
    private(set) var hosts: [SavedHost] = []
    private let url = appSupportURL("hosts.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([SavedHost].self, from: data) {
            hosts = decoded
        }
    }

    func add(_ host: SavedHost) { hosts.append(host); save() }
    func remove(_ host: SavedHost) { hosts.removeAll { $0.id == host.id }; save() }

    private func save() { try? JSONEncoder().encode(hosts).write(to: url) }
}

/// Persisted known_hosts (the stored host keys are public, so a plain file is
/// fine). The TOFU prompt + trust decision live in the UI.
@MainActor
@Observable
final class KnownHostsStore {
    private(set) var knownHosts = KnownHosts()
    private let url = appSupportURL("known_hosts.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(KnownHosts.self, from: data) {
            knownHosts = decoded
        }
    }

    func trust(host: String, port: UInt16, key: HostKey) {
        var updated = knownHosts
        updated.trust(host: host, port: port, key: key)
        knownHosts = updated
        try? JSONEncoder().encode(knownHosts).write(to: url)
    }
}
