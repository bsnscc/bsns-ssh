import Foundation
import Observation
import BsnsSSHCore

/// App-level holder for the agent and its visible identities. The agent is the
/// heart — every key the UI shows or uses lives here, and (later) every SSH
/// connection authenticates through it.
@MainActor
@Observable
final class AgentStore {
    let agent = Agent()
    private(set) var identities: [SSHPublicKey] = []

    func refresh() async {
        identities = await agent.identities()
    }

    func generateKey(_ algorithm: KeyAlgorithm) async {
        guard let key = try? FileKey.generate(algorithm: algorithm, comment: "generated on device") else {
            return
        }
        await agent.add(key)
        await refresh()
    }
}
