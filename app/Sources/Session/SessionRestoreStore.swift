import Foundation
import Observation

/// A snapshot of a live session sufficient to re-create and reconnect it after the
/// app is terminated in the background (which iOS does within minutes — the whole
/// process, its UDP socket, and mosh client state are gone on relaunch). The live
/// `Spec` can't be persisted (it holds the `Agent` and `KnownHosts` objects), so we
/// store the plain fields and rebuild the `Spec` at launch from the stores. The
/// public key blob is fine on disk (it isn't secret); signing still needs the agent
/// to hold the matching private key. Jump sessions are intentionally not persisted —
/// dropping a bastion on restore could connect/trust the wrong endpoint.
struct RestorableSession: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var host: String
    var port: UInt16
    var user: String
    var useMosh: Bool
    var keyBlob: Data?
    var tmuxSession: String?
}

/// Persists the set of open sessions to a JSON file so they can be reconnected on
/// the next launch. Mirrors `SnippetStore`'s file-backed pattern. Not secret —
/// host/user/public-key only.
@MainActor
@Observable
final class SessionRestoreStore {
    private(set) var sessions: [RestorableSession] = []
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([RestorableSession].self, from: data) {
            sessions = decoded
        }
    }

    /// Snapshot taken at launch, before live sessions overwrite the store — what we
    /// reconnect on relaunch.
    func snapshotForRestore() -> [RestorableSession] { sessions }

    func remember(_ s: RestorableSession) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s }
        else { sessions.append(s) }
        save()
    }

    func forget(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    private func save() { try? JSONEncoder().encode(sessions).write(to: url) }
}
