import Foundation
import Observation
import BsnsSSHCore

/// App-level holder for the agent and its visible identities. The agent is the
/// heart — every key the UI shows or uses lives here. Keys are persisted in the
/// Keychain and reloaded into the agent on launch.
@MainActor
@Observable
final class AgentStore {
    let agent = Agent()
    private(set) var identities: [SSHPublicKey] = []
    /// Fingerprints of keys held in hardware (Secure Enclave) — used to badge them.
    private(set) var hardwareKeyIDs: Set<String> = []

    /// Whether this device can create Secure Enclave keys (false on the simulator).
    var enclaveAvailable: Bool { SecureEnclaveKey.isAvailable }

    init() {
        Task {
            for key in KeyStore.loadAll() {
                await agent.add(key)
                if key.requiresUserPresence { hardwareKeyIDs.insert(key.id.rawValue) }
            }
            await refresh()
        }
    }

    func refresh() async {
        identities = await agent.identities()
    }

    func generateKey(_ algorithm: KeyAlgorithm) async {
        guard let key = try? FileKey.generate(algorithm: algorithm, comment: "generated on device") else {
            return
        }
        KeyStore.save(key)
        await agent.add(key)
        await refresh()
    }

    /// Create a non-extractable P-256 key in the Secure Enclave (Face ID per use).
    func generateEnclaveKey() async throws {
        let key = try SecureEnclaveKey.generate(comment: "Secure Enclave key")
        KeyStore.saveEnclave(key)
        await agent.add(key)
        hardwareKeyIDs.insert(key.id.rawValue)
        await refresh()
    }

    func isHardware(_ identity: SSHPublicKey) -> Bool {
        hardwareKeyIDs.contains(SSHKeyFormat.fingerprint(ofPublicKeyBlob: identity.blob))
    }

    /// Software keys currently held (for export).
    func exportableKeys() -> [FileKey] { KeyStore.loadFileKeys() }

    /// Import a software key from a config bundle, skipping duplicates.
    func importKey(_ key: FileKey) async {
        let existing = Set(identities.map { SSHKeyFormat.fingerprint(ofPublicKeyBlob: $0.blob) })
        guard !existing.contains(SSHKeyFormat.fingerprint(ofPublicKeyBlob: key.publicKey.blob)) else { return }
        KeyStore.save(key)
        await agent.add(key)
        await refresh()
    }

    func deleteKey(_ identity: SSHPublicKey) async {
        let id = KeyID(SSHKeyFormat.fingerprint(ofPublicKeyBlob: identity.blob))
        KeyStore.delete(id)
        await agent.remove(id)
        hardwareKeyIDs.remove(id.rawValue)
        await refresh()
    }
}
