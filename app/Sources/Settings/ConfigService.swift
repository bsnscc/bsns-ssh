import Foundation
import BsnsSSHCore

/// Builds and applies config bundles across the stores.
@MainActor
enum ConfigService {
    static func export(hosts: HostStore, knownHosts: KnownHostsStore, agent: AgentStore,
                       includeKeys: Bool, passphrase: String?) throws -> Data {
        var bundle = ConfigBundle(hosts: hosts.hosts, knownHosts: knownHosts.knownHosts, settings: .capture())
        if includeKeys {
            bundle.keys = agent.exportableKeys().map {
                ExportedKey(algorithm: $0.algorithm.rawValue,
                            material: $0.exportPrivateKeyMaterial(),
                            comment: $0.publicKey.comment)
            }
        }
        let json = try JSONEncoder().encode(bundle)
        if let pass = passphrase, !pass.isEmpty {
            return try ConfigCrypto.encrypt(json, passphrase: pass)
        }
        return json
    }

    /// Result of inspecting an import file before applying it.
    enum Inspection { case plain(ConfigBundle), encrypted }

    static func inspect(_ data: Data) -> Inspection {
        if ConfigCrypto.isEncrypted(data) { return .encrypted }
        if let bundle = try? JSONDecoder().decode(ConfigBundle.self, from: data) { return .plain(bundle) }
        return .encrypted   // unknown → treat as needing a passphrase / unreadable
    }

    static func decode(_ data: Data, passphrase: String?) throws -> ConfigBundle {
        var json = data
        if ConfigCrypto.isEncrypted(data) {
            guard let pass = passphrase, !pass.isEmpty else { throw ConfigCryptoError.badPassphrase }
            json = try ConfigCrypto.decrypt(data, passphrase: pass)
        }
        guard let bundle = try? JSONDecoder().decode(ConfigBundle.self, from: json) else {
            throw ConfigCryptoError.badFormat
        }
        return bundle
    }

    static func apply(_ bundle: ConfigBundle, hosts: HostStore, knownHosts: KnownHostsStore, agent: AgentStore) async {
        hosts.merge(bundle.hosts)
        knownHosts.merge(bundle.knownHosts)
        bundle.settings.apply()
        for k in bundle.keys ?? [] {
            if let algo = KeyAlgorithm(rawValue: k.algorithm),
               let key = try? FileKey.from(algorithm: algo, privateKeyMaterial: k.material, comment: k.comment) {
                await agent.importKey(key)
            }
        }
    }
}
