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
    static func autoPush(sync: SyncStore, hosts: HostStore, knownHosts: KnownHostsStore, agent: AgentStore, snippets: SnippetStore) {
        let start = Date()
        DiagLog.log("sync", "autoPush start configured=\(sync.isConfigured) passphrase=\(sync.hasPassphrase)")
        guard sync.autoEnabled else {
            DiagLog.log("sync", "autoPush skip disabled")
            return
        }
        guard let pass = sync.loadPassphrase() else {
            DiagLog.log("sync", "autoPush skip no passphrase")
            return
        }
        do {
            let softwareKeys = agent.exportableKeys().count
            let securityKeys = agent.exportableSecurityKeyMetadata().count
            DiagLog.log("sync", "autoPush export begin hosts=\(hosts.hosts.count) knownHosts=\(knownHosts.knownHosts.allEntries.count) softwareKeys=\(softwareKeys) securityKeys=\(securityKeys) snippets=\(snippets.snippets.count)")
            let data = try ConfigService.export(hosts: hosts, knownHosts: knownHosts, agent: agent,
                                                snippets: snippets, includeKeys: true, passphrase: pass)
            // Hash the plaintext snapshot (not the ciphertext — encryption is salted
            // and differs each time) so an unchanged config doesn't rewrite the file.
            let plain = try ConfigService.export(hosts: hosts, knownHosts: knownHosts, agent: agent,
                                                 snippets: snippets, includeKeys: true, passphrase: nil)
            let hash = SHA256.hash(data: plain).map { String(format: "%02x", $0) }.joined()
            guard hash != sync.lastHash else {
                DiagLog.log("sync", "autoPush skip unchanged elapsed=\(elapsedMS(since: start))ms")
                return
            }
            DiagLog.log("sync", "autoPush write begin encryptedBytes=\(data.count) plainBytes=\(plain.count)")
            try sync.push(data)
            sync.lastHash = hash
            DiagLog.log("sync", "autoPush ok elapsed=\(elapsedMS(since: start))ms")
        } catch {
            DiagLog.log("sync", "autoPush failed elapsed=\(elapsedMS(since: start))ms error=\(error.localizedDescription)")
        }
    }

    /// Pull the folder's bundle and merge it into this device (every category).
    /// No-ops quietly when auto-sync isn't set up or there's nothing to pull.
    static func autoPull(sync: SyncStore, hosts: HostStore, knownHosts: KnownHostsStore, agent: AgentStore, snippets: SnippetStore) async {
        let start = Date()
        DiagLog.log("sync", "autoPull start configured=\(sync.isConfigured) passphrase=\(sync.hasPassphrase)")
        guard sync.autoEnabled else {
            DiagLog.log("sync", "autoPull skip disabled")
            return
        }
        guard let pass = sync.loadPassphrase() else {
            DiagLog.log("sync", "autoPull skip no passphrase")
            return
        }
        do {
            let data = try sync.pull()
            DiagLog.log("sync", "autoPull read bytes=\(data.count)")
            let bundle = try ConfigService.decode(data, passphrase: pass)
            // Snippets come across too (synced ones land with run-on-connect off in apply()).
            let selection = ConfigService.ImportSelection(hosts: true, settings: true, knownHosts: true,
                                                          keys: true, securityKeys: true, snippets: true)
            await ConfigService.apply(bundle, selection: selection, hosts: hosts, knownHosts: knownHosts, agent: agent, snippets: snippets)
            DiagLog.log("sync", "autoPull ok elapsed=\(elapsedMS(since: start))ms")
        } catch {
            DiagLog.log("sync", "autoPull failed elapsed=\(elapsedMS(since: start))ms error=\(error.localizedDescription)")
        }
    }

    private static func elapsedMS(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
