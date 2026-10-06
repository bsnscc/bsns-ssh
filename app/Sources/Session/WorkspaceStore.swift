import Foundation
import Observation
import BsnsSSHCore

/// The user's workspaces, kept in a file and carried between devices in the
/// sync bundle beside the saved hosts.
@MainActor
@Observable
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    private(set) var workspaces: [Workspace] = []
    @ObservationIgnored private let url = AppPaths.support.appendingPathComponent("workspaces.json")

    private init() {
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([Workspace].self, from: data) {
            workspaces = decoded
        }
    }

    func upsert(_ workspace: Workspace) {
        var workspace = workspace
        workspace.modifiedAt = Date()
        if let i = workspaces.firstIndex(where: { $0.id == workspace.id }) { workspaces[i] = workspace }
        else { workspaces.append(workspace) }
        save()
    }

    func remove(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        save()
    }

    /// Take in workspaces from a bundle. A status command is something that
    /// runs on the user's machines, so — as with snippets that run on connect —
    /// a bundle can't introduce or change one: an incoming command is kept only
    /// where this device already has that exact command for that workspace.
    func merge(_ incoming: [Workspace]) {
        for var workspace in incoming {
            let existing = workspaces.first { $0.id == workspace.id }
            if let modified = existing?.modifiedAt, modified >= (workspace.modifiedAt ?? .distantPast) { continue }
            if existing?.statusCommand != workspace.statusCommand { workspace.statusCommand = existing?.statusCommand }
            if let i = workspaces.firstIndex(where: { $0.id == workspace.id }) { workspaces[i] = workspace }
            else { workspaces.append(workspace) }
        }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(workspaces).write(to: url, options: .atomic)
    }
}
