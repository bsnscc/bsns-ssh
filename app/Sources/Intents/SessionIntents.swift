import AppIntents
import Foundation
import BsnsSSHCore

/// What a shortcut needs from the running app. Set once the stores exist; an
/// intent that arrives during launch waits briefly for it.
@MainActor
final class AppContext {
    static let shared = AppContext()
    weak var store: AgentStore?
    weak var hosts: HostStore?
    weak var knownHosts: KnownHostsStore?
    weak var sessions: SessionStore?

    struct Ready {
        let store: AgentStore, hosts: HostStore, knownHosts: KnownHostsStore, sessions: SessionStore
    }

    func ready() async throws -> Ready {
        for _ in 0..<40 {
            if let store, let hosts, let knownHosts, let sessions {
                return Ready(store: store, hosts: hosts, knownHosts: knownHosts, sessions: sessions)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw IntentFailure.message("bsns.SSH isn't ready yet — open it and try again.")
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case message(String)
    var localizedStringResource: LocalizedStringResource {
        switch self { case .message(let text): return "\(text)" }
    }
}

/// A saved host, as a shortcut picks it.
struct HostEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved Host"
    static let defaultQuery = HostQuery()

    let id: String
    let name: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }

    init(_ host: SavedHost) {
        id = host.id.uuidString
        name = host.label.isEmpty ? host.host : host.label
        detail = "\(host.user)@\(host.host)"
    }
}

struct HostQuery: EntityQuery {
    /// Read from the saved-hosts file, so the picker works without the app's
    /// screens being up.
    private func saved() -> [SavedHost] {
        let url = AppPaths.support.appendingPathComponent("hosts.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SavedHost].self, from: data)) ?? []
    }

    func entities(for identifiers: [String]) async throws -> [HostEntity] {
        saved().filter { identifiers.contains($0.id.uuidString) }.map(HostEntity.init)
    }

    func suggestedEntities() async throws -> [HostEntity] {
        saved().filter { ($0.jump ?? "").isEmpty }.map(HostEntity.init)
    }
}

/// Open a session on a saved host — from a widget, Siri, or a shortcut that a
/// notification runs.
struct OpenSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Session"
    static let description = IntentDescription("Opens a session on one of your saved hosts, attaching a tmux session if you name one.")
    static let openAppWhenRun = true

    @Parameter(title: "Host") var host: HostEntity
    @Parameter(title: "tmux Session") var tmux: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$host)") { \.$tmux }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let context = try await AppContext.shared.ready()
        guard let saved = context.hosts.hosts.first(where: { $0.id.uuidString == host.id }) else {
            throw IntentFailure.message("That host is no longer saved.")
        }
        guard SessionOpener.open(saved, tmux: tmux, sessions: context.sessions, store: context.store,
                                 knownHosts: context.knownHosts) != nil else {
            throw IntentFailure.message("\(host.name) is reached through a jump host; open it from Connect.")
        }
        return .result()
    }
}

/// Open a workspace on one of its machines.
struct OpenWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Workspace"
    static let description = IntentDescription("Opens a workspace's tmux session on one of its machines.")
    static let openAppWhenRun = true

    @Parameter(title: "Workspace") var workspace: String
    @Parameter(title: "Host") var host: HostEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Open workspace \(\.$workspace)") { \.$host }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let context = try await AppContext.shared.ready()
        let chosen = host.flatMap { picked in context.hosts.hosts.first { $0.id.uuidString == picked.id } }
        guard let url = DeepLink.workspace(name: workspace, host: chosen?.host).url else {
            throw IntentFailure.message("That isn't a workspace name.")
        }
        if let problem = SessionOpener.follow(url, hosts: context.hosts, sessions: context.sessions,
                                              store: context.store, knownHosts: context.knownHosts) {
            throw IntentFailure.message(problem)
        }
        return .result()
    }
}

/// Run one command on a saved host and hand its output back to the shortcut.
///
/// The app comes to the front for this: the key that signs in lives here, and
/// a hardware-backed key asks for Face ID. The command is always shown for
/// confirmation first, so a shortcut can't run something on a server unseen.
struct RunCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Command on Host"
    static let description = IntentDescription("Runs a command on one of your saved hosts over SSH and returns what it printed.")
    static let openAppWhenRun = true

    @Parameter(title: "Host") var host: HostEntity
    @Parameter(title: "Command") var command: String

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) on \(\.$host)")
    }

    static let outputLimit = 8_000

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let context = try await AppContext.shared.ready()
        guard let saved = context.hosts.hosts.first(where: { $0.id.uuidString == host.id }) else {
            throw IntentFailure.message("That host is no longer saved.")
        }
        guard (saved.jump ?? "").isEmpty else {
            throw IntentFailure.message("\(host.name) is reached through a jump host, which shortcuts can't use yet.")
        }
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IntentFailure.message("There is no command to run.") }
        try await requestConfirmation(result: .result(dialog: "Run “\(text)” on \(host.name)?"))

        let channel = SSHExecSession()
        defer { channel.close() }
        do {
            try await withLinkTimeout(45) {
                try await channel.connect(host: saved.host, port: UInt16(clamping: saved.port), user: saved.user,
                                          agent: context.store.agent, knownHosts: context.knownHosts.knownHosts,
                                          keyBlob: SessionOpener.key(for: saved, store: context.store))
            }
            let result = try await withLinkTimeout(60) { try await channel.run(text) }
            var output = result.stdoutString
            if output.isEmpty { output = result.stderrString }
            if output.count > Self.outputLimit { output = String(output.prefix(Self.outputLimit)) + "\n…" }
            return .result(value: output.trimmingCharacters(in: .newlines))
        } catch {
            throw IntentFailure.message("Couldn't run that on \(host.name): \(TerminalSession.describe(error))")
        }
    }
}

struct BsnsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenSessionIntent(),
                    phrases: ["Open a session in \(.applicationName)", "Connect with \(.applicationName)"],
                    shortTitle: "Open Session", systemImageName: "terminal")
        AppShortcut(intent: RunCommandIntent(),
                    phrases: ["Run a command with \(.applicationName)"],
                    shortTitle: "Run Command", systemImageName: "chevron.left.forwardslash.chevron.right")
        AppShortcut(intent: OpenWorkspaceIntent(),
                    phrases: ["Open a workspace in \(.applicationName)"],
                    shortTitle: "Open Workspace", systemImageName: "folder")
    }
}
