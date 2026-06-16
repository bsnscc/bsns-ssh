import Foundation
import BsnsSSHCore

/// Builds and applies config bundles across the stores.
@MainActor
enum ConfigService {
    static func export(hosts: HostStore, knownHosts: KnownHostsStore, agent: AgentStore,
                       snippets: SnippetStore, includeKeys: Bool, passphrase: String?) throws -> Data {
        var bundle = ConfigBundle(hosts: hosts.hosts, knownHosts: knownHosts.knownHosts,
                                  settings: .capture(), snippets: snippets.snippets)
        // Invariant enforced here (not only in the UI): private keys are NEVER
        // emitted into a plaintext bundle — only when a passphrase will encrypt it.
        let encrypting = !(passphrase ?? "").isEmpty
        if includeKeys && encrypting {
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

    /// What the user chose to import. Hosts and settings are low-risk and on by
    /// default; the two security-sensitive categories are opt-in: importing
    /// trusted host keys pre-trusts servers (bypassing the TOFU prompt), and
    /// importing private keys loads extractable key material into the agent.
    struct ImportSelection {
        var hosts = true
        var settings = true
        var knownHosts = false
        var keys = false
        var snippets = false   // executable config → opt-in; imported ones never run-on-connect
    }

    static func apply(_ bundle: ConfigBundle, selection: ImportSelection,
                      hosts: HostStore, knownHosts: KnownHostsStore, agent: AgentStore,
                      snippets: SnippetStore) async {
        if selection.hosts { hosts.merge(bundle.hosts) }
        if selection.settings { bundle.settings.apply() }
        if selection.knownHosts { knownHosts.merge(bundle.knownHosts) }
        if selection.keys {
            for k in bundle.keys ?? [] {
                if let algo = KeyAlgorithm(rawValue: k.algorithm),
                   let key = try? FileKey.from(algorithm: algo, privateKeyMaterial: k.material, comment: k.comment) {
                    await agent.importKey(key)
                }
            }
        }
        if selection.snippets {
            // A bundle (manual import OR trusted auto-sync) can never ARM run-on-
            // connect — that would let it inject an auto-running command. We keep an
            // existing local snippet's auto-run flag ONLY when the command is byte-
            // identical, so a steady-state sync doesn't disarm local automation; but
            // if the bundle changes the command for that ID (or the snippet is new),
            // it lands with auto-run OFF.
            let existing = Dictionary(snippets.snippets.map { ($0.id, $0) },
                                      uniquingKeysWith: { a, _ in a })
            for s in bundle.snippets ?? [] {
                let keepRun = existing[s.id].map { $0.runOnConnect && $0.command == s.command } ?? false
                snippets.upsert(Snippet(id: s.id, name: s.name, command: s.command, runOnConnect: keepRun))
            }
        }
    }
}
