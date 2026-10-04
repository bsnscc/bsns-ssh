import Foundation
import Observation
import Security
import BsnsSSHCore

/// This device's link identity and the devices it is paired with.
///
/// The identity's private key is in the keychain (this device only). The
/// paired devices — public keys and names, plus on a computer the public keys
/// each phone offered — are not secret and live in a file.
@MainActor
@Observable
final class LinkStore {
    static let shared = LinkStore()

    struct Paired: Codable, Identifiable, Equatable {
        var peer: LinkPeer
        /// Public keys the paired device has offered (computer side).
        var identities: [Offered] = []
        var id: String { peer.id }

        struct Offered: Codable, Equatable {
            var blob: Data
            var comment: String
        }
    }

    /// This device's long-term link key. Loaded on first use rather than at
    /// launch: most launches never need it, and reading the keychain can stop
    /// to ask the user.
    var identity: LinkIdentity {
        if let loadedIdentity { return loadedIdentity }
        let identity = LinkStore.loadIdentity()
        loadedIdentity = identity
        return identity
    }
    @ObservationIgnored private var loadedIdentity: LinkIdentity?
    private(set) var paired: [Paired] = []

    @ObservationIgnored private let url = AppPaths.support.appendingPathComponent("paired-devices.json")
    // Read from connection handlers off the main thread.
    @ObservationIgnored private let snapshotLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var pairedKeys: [Data: String] = [:]

    private init() {
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([Paired].self, from: data) {
            paired = decoded
        }
        publishSnapshot()
    }

    /// The name of a paired device, by its public key — nil if it isn't paired.
    nonisolated func pairedName(forPublicKey key: Data) -> String? {
        snapshotLock.withLock { pairedKeys[key] }
    }

    func add(_ peer: LinkPeer) {
        if let i = paired.firstIndex(where: { $0.peer.publicKey == peer.publicKey }) {
            paired[i].peer = peer
        } else {
            paired.append(Paired(peer: peer))
        }
        save()
    }

    func remove(_ id: String) {
        paired.removeAll { $0.id == id }
        save()
    }

    func setIdentities(_ identities: [SSHPublicKey], for id: String) {
        guard let i = paired.firstIndex(where: { $0.id == id }) else { return }
        paired[i].identities = identities.map { Paired.Offered(blob: $0.blob, comment: $0.comment) }
        save()
    }

    private func save() {
        publishSnapshot()
        try? JSONEncoder().encode(paired).write(to: url, options: .atomic)
    }

    private func publishSnapshot() {
        let keys = Dictionary(paired.map { ($0.peer.publicKey, $0.peer.name) }, uniquingKeysWith: { first, _ in first })
        snapshotLock.withLock { pairedKeys = keys }
    }

    // MARK: identity (keychain)

    private static let service = "cc.bsns.ssh.link"
    private static let account = "identity"

    private static func loadIdentity() -> LinkIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
           let identity = try? LinkIdentity(privateKeyData: data) {
            return identity
        }
        // First use on this device: make one and keep it. If the keychain
        // refuses, the identity lasts for this run only and pairings made with
        // it won't survive a relaunch — better than failing to start.
        let identity = LinkIdentity()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: identity.privateKeyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess { DiagLog.log("link", "identity save failed status=\(status)") }
        return identity
    }
}
