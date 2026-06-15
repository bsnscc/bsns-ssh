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

    init() {
        Task {
            for key in KeyStore.loadAll() { await agent.add(key) }
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

    func deleteKey(_ identity: SSHPublicKey) async {
        let id = KeyID(SSHKeyFormat.fingerprint(ofPublicKeyBlob: identity.blob))
        KeyStore.delete(id)
        await agent.remove(id)
        await refresh()
    }
}
