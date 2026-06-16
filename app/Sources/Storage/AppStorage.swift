import Foundation
import Observation
import BsnsSSHCore

/// A saved connection target. Optional fields decode as nil from older
/// `hosts.json` files (written before per-host mosh / jump / groups).
/// `jump` is a ProxyJump spec ("user@bastion[:port]"); `group` is a folder label.
struct SavedHost: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var host: String
    var port: Int
    var user: String
    var useMosh: Bool?
    var jump: String?
    var group: String?
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

    /// Add imported hosts, skipping ones that already match by host/port/user.
    func merge(_ incoming: [SavedHost]) {
        let existing = Set(hosts.map { "\($0.user)@\($0.host):\($0.port)" })
        for h in incoming where !existing.contains("\(h.user)@\(h.host):\(h.port)") { hosts.append(h) }
        save()
    }

    /// Import `ssh_config` Host blocks as saved hosts (carrying ProxyJump). Returns
    /// the count imported.
    @discardableResult
    func importConfig(_ configHosts: [SSHConfigHost]) -> Int {
        let mapped = configHosts.map {
            SavedHost(label: $0.alias == $0.hostName ? "" : $0.alias,
                      host: $0.hostName, port: $0.port, user: $0.user ?? "",
                      jump: $0.proxyJump)
        }
        let before = hosts.count
        merge(mapped)
        return hosts.count - before
    }

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

    func forget(_ identifier: String) {
        var updated = knownHosts
        updated.forget(identifier)
        knownHosts = updated
        try? JSONEncoder().encode(knownHosts).write(to: url)
    }

    /// Union imported trusted hosts into ours (existing entries win on conflict).
    func merge(_ incoming: KnownHosts) {
        knownHosts = KnownHosts(entries: incoming.allEntries.merging(knownHosts.allEntries) { _, mine in mine })
        try? JSONEncoder().encode(knownHosts).write(to: url)
    }

    /// Trust host keys parsed from a `known_hosts` file (existing entries win).
    /// The key type is read from the blob's leading SSH string. Returns the count.
    @discardableResult
    func importEntries(_ imported: [KnownHostImport]) -> Int {
        var entries = knownHosts.allEntries
        var added = 0
        for e in imported where entries[e.identifier] == nil {
            var dec = SSHDecoder(e.blob)
            let keyType = (try? dec.readStringUTF8()) ?? "ssh-unknown"
            entries[e.identifier] = HostKey(keyType: keyType, blob: e.blob)
            added += 1
        }
        knownHosts = KnownHosts(entries: entries)
        try? JSONEncoder().encode(knownHosts).write(to: url)
        return added
    }
}
