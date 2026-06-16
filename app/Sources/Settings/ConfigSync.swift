import Foundation
import CryptoKit

/// Automatic sync glue over `SyncStore` + `ConfigService`: push the encrypted
/// bundle to the user's folder when the app backgrounds, and pull + merge it on
/// launch. The provider only ever sees ciphertext (no account, no server of
/// ours). Additive merge — matches the manual import. Because the folder +
/// passphrase were configured by the user, auto-pull applies every category
/// (hosts, trusted keys, settings, software keys) without the review dialog.
@MainActor
enum ConfigSync {
    /// Push the current config (incl. software keys) if auto-sync is on and it
    /// changed since the last sync. Safe to call often.
    static func autoPush(sync: SyncStore, hosts: HostStore, knownHosts: KnownHostsStore, agent: AgentStore) {
        guard sync.autoEnabled, let pass = sync.loadPassphrase() else { return }
        guard let data = try? ConfigService.export(hosts: hosts, knownHosts: knownHosts, agent: agent,
                                                   includeKeys: true, passphrase: pass) else { return }
        // Hash the plaintext snapshot (not the ciphertext — encryption is salted
        // and differs each time) so an unchanged config doesn't rewrite the file.
        guard let plain = try? ConfigService.export(hosts: hosts, knownHosts: knownHosts, agent: agent,
                                                    includeKeys: true, passphrase: nil) else { return }
        let hash = SHA256.hash(data: plain).map { String(format: "%02x", $0) }.joined()
        guard hash != sync.lastHash else { return }
        if (try? sync.push(data)) != nil { sync.lastHash = hash }
    }

    /// Pull the folder's bundle and merge it into this device (every category).
    /// No-ops quietly when auto-sync isn't set up or there's nothing to pull.
    static func autoPull(sync: SyncStore, hosts: HostStore, knownHosts: KnownHostsStore, agent: AgentStore) async {
        guard sync.autoEnabled, let pass = sync.loadPassphrase() else { return }
        guard let data = try? sync.pull(), let bundle = try? ConfigService.decode(data, passphrase: pass) else { return }
        let selection = ConfigService.ImportSelection(hosts: true, settings: true, knownHosts: true, keys: true)
        await ConfigService.apply(bundle, selection: selection, hosts: hosts, knownHosts: knownHosts, agent: agent)
    }
}
