import Foundation

/// A project the user works on from more than one machine: one repository, at
/// a path on each machine that has it. Opening a workspace on a machine means
/// attaching the tmux session named after it there (created in the project
/// directory the first time), so "the same workspace on the other machine" is
/// always found under the same name.
public struct Workspace: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Where the project lives on a machine — the same path everywhere unless
    /// `pathOverrides` says otherwise for a host.
    public var path: String
    /// Per-host paths, keyed by the saved host's name (lowercased).
    public var pathOverrides: [String: String]?
    /// The repository's remote, for reference.
    public var repository: String?
    /// The saved hosts (by name) that have this project.
    public var hosts: [String]
    /// A command run in the project directory to describe its state on a
    /// machine — how fresh a mirror is, say. Its first lines are shown as is.
    public var statusCommand: String?
    /// An explicit session preserves existing host connections when adopting a layout.
    public var sessionName: String?
    /// Named full-screen windows, shared by every device. No executable commands.
    public var windows: [WorkspaceWindow]?
    public var modifiedAt: Date? = nil

    public init(id: UUID = UUID(), name: String, path: String, pathOverrides: [String: String]? = nil,
                repository: String? = nil, hosts: [String] = [], statusCommand: String? = nil, sessionName: String? = nil, windows: [WorkspaceWindow]? = nil) {
        self.id = id; self.name = name; self.path = path; self.pathOverrides = pathOverrides
        self.repository = repository; self.hosts = hosts; self.statusCommand = statusCommand
        self.sessionName = sessionName; self.windows = windows
    }

    /// The tmux session every machine uses for this workspace. Nil when the
    /// name has nothing tmux can use.
    public var tmuxSession: String? { MoshServerCommand.sanitizedTmuxName((sessionName ?? name).replacingOccurrences(of: " ", with: "-")) }

    public func path(on host: String?) -> String {
        host.flatMap { pathOverrides?[$0.lowercased()] } ?? path
    }

    public func includes(host: String) -> Bool {
        hosts.contains { $0.caseInsensitiveCompare(host) == .orderedSame }
    }
}

/// A portable window role. A nil directory uses the workspace path on the chosen host.
public struct WorkspaceWindow: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var index: Int
    public var name: String
    public var directory: String?
    /// A label for what the window is for — "editor", "review". Only the label
    /// travels with the workspace: what it runs is defined on each host, so a
    /// synced definition can never choose a command.
    public var tool: String?

    public static let maxToolLength = 32

    public init(id: UUID = UUID(), index: Int, name: String, directory: String? = nil, tool: String? = nil) {
        self.id = id; self.index = index; self.name = name
        self.directory = directory; self.tool = tool
    }

    private enum CodingKeys: String, CodingKey { case id, index, name, directory, tool, agent }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        index = try values.decode(Int.self, forKey: .index)
        name = try values.decode(String.self, forKey: .name)
        directory = try values.decodeIfPresent(String.self, forKey: .directory)
        // `agent` is the field's earlier name; definitions saved then still load.
        tool = try values.decodeIfPresent(String.self, forKey: .tool)
            ?? values.decodeIfPresent(String.self, forKey: .agent)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(index, forKey: .index)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(directory, forKey: .directory)
        try values.encodeIfPresent(tool, forKey: .tool)
    }

    public var isValid: Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return (0...999).contains(index) && !name.isEmpty && name.count <= 80
            && name.allSatisfy { allowed.contains($0) }
            && (directory == nil || WorkspaceCommand.quoted(directory!) != nil)
            && (tool == nil || (!tool!.isEmpty && tool!.count <= Self.maxToolLength && tool!.allSatisfy { allowed.contains($0) }))
    }
}

/// What a workspace looks like on one machine right now.
public struct WorkspaceStatus: Equatable, Sendable {
    public var exists = false
    public var branch: String?
    /// Files with uncommitted changes.
    public var dirty: Int?
    /// Commits not yet on the upstream branch (nil when there is no upstream).
    public var ahead: Int?
    /// The first lines of the workspace's status command, verbatim.
    public var statusLines: [String] = []

    public init() {}

    /// "main · 3 changed · 2 unpushed"
    public var summary: String {
        guard exists else { return "not on this machine" }
        var parts: [String] = []
        if let branch, !branch.isEmpty { parts.append(branch) }
        if let dirty, dirty > 0 { parts.append("\(dirty) changed") }
        if let ahead, ahead > 0 { parts.append("\(ahead) unpushed") }
        if parts.count <= 1, dirty == 0 { parts.append("clean") }
        return parts.isEmpty ? "no repository" : parts.joined(separator: " · ")
    }
}

public enum WorkspaceCommand {
    /// Update the selected host's cached definition and restore missing windows.
    /// The helper accepts structured data only; synced workspaces cannot run commands.
    public static func prepare(_ workspace: Workspace, host: String? = nil) -> String? {
        guard let windows = workspace.windows, !windows.isEmpty else { return nil }
        guard windows.count <= 50, windows.allSatisfy(\.isValid),
              Set(windows.map(\.id)).count == windows.count,
              Set(windows.map(\.name)).count == windows.count,
              Set(windows.map(\.index)).count == windows.count,
              let session = workspace.tmuxSession, !session.isEmpty else { return nil }
        var resolved = workspace
        resolved.path = workspace.path(on: host)
        resolved.pathOverrides = nil
        resolved.sessionName = session
        guard quoted(resolved.path) != nil, let data = try? JSONEncoder().encode(resolved) else { return nil }
        return TmuxCommand.script("\"$HOME/.local/bin/bsns-workspace\" apply \(data.base64EncodedString())")
    }

    static let marker = "ws"
    public static let maxStatusLines = 4

    /// A path as it may appear inside double quotes in a POSIX script, or nil
    /// if it contains anything that would mean something there. A leading `~`
    /// becomes `$HOME`, since tilde doesn't expand inside quotes.
    public static func quoted(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 1024,
              !trimmed.contains(where: { "\"'$`\\\n\r!".contains($0) }) else { return nil }
        if trimmed == "~" { return "\"$HOME\"" }
        if trimmed.hasPrefix("~/") { return "\"$HOME/\(trimmed.dropFirst(2))\"" }
        guard trimmed.hasPrefix("/") else { return nil }
        return "\"\(trimmed)\""
    }

    /// The status command is the user's own, run as them on their own machine;
    /// it only has to survive being placed in a single-quoted script.
    public static func isUsable(statusCommand: String) -> Bool {
        !statusCommand.contains("'") && !statusCommand.contains("\n") && statusCommand.count <= 500
    }

    /// Report a workspace's state on the machine this runs on: branch, changed
    /// files, unpushed commits, and the head of the status command's output.
    /// Read-only. Nil when the path can't be passed safely.
    public static func status(path: String, statusCommand: String?) -> String? {
        guard let dir = quoted(path) else { return nil }
        let f = TmuxCommand.fieldSeparator
        var body = "cd \(dir) 2>/dev/null || { echo \"\(marker)\(f)missing\"; exit 0; }; "
            + "echo \"\(marker)\(f)here\"; "
            + "if git rev-parse --git-dir >/dev/null 2>&1; then "
            + "echo \"\(marker)\(f)branch\(f)$(git rev-parse --abbrev-ref HEAD 2>/dev/null)\"; "
            + "echo \"\(marker)\(f)dirty\(f)$(git status --porcelain 2>/dev/null | wc -l | tr -d \" \")\"; "
            + "a=$(git rev-list --count \"@{u}..HEAD\" 2>/dev/null) && echo \"\(marker)\(f)ahead\(f)$a\"; "
            + "fi; "
        if let command = statusCommand?.trimmingCharacters(in: .whitespaces), !command.isEmpty, isUsable(statusCommand: command) {
            body += "{ \(command) ; } 2>&1 | head -\(maxStatusLines) | while IFS= read -r l; do echo \"\(marker)\(f)status\(f)$l\"; done; "
        }
        return TmuxCommand.script(body + "true")
    }

    /// Nil when the output has none of the expected rows (the command didn't run).
    public static func parseStatus(_ output: String) -> WorkspaceStatus? {
        var status = WorkspaceStatus()
        var sawAny = false
        for row in output.split(whereSeparator: \.isNewline) {
            let fields = row.components(separatedBy: TmuxCommand.fieldSeparator)
            guard fields.first == marker, fields.count >= 2 else { continue }
            sawAny = true
            let value = fields.dropFirst(2).joined(separator: TmuxCommand.fieldSeparator)
            switch fields[1] {
            case "here": status.exists = true
            case "missing": status.exists = false
            case "branch": status.branch = value
            case "dirty": status.dirty = Int(value)
            case "ahead": status.ahead = Int(value)
            case "status": if status.statusLines.count < maxStatusLines { status.statusLines.append(value) }
            default: break
            }
        }
        return sawAny ? status : nil
    }

    /// Which machine to suggest for new work: the reachable one with the most
    /// spare capacity, by load per core. Ties go to the first listed.
    public static func leastBusy<ID>(_ machines: [(id: ID, load: Double?, cpus: Int?)]) -> ID? {
        machines.compactMap { machine -> (ID, Double)? in
            guard let load = machine.load else { return nil }
            return (machine.id, load / Double(max(machine.cpus ?? 1, 1)))
        }.min { $0.1 < $1.1 }?.0 ?? machines.first?.id
    }
}

/// A link that opens something in the app: `bsns-ssh://open?host=studio&tmux=main`
/// or `bsns-ssh://workspace?name=site&host=studio`. A link names things the
/// user has already saved — it never carries an address, a key or a secret, so
/// following one can't make the app connect anywhere new.
public enum DeepLink: Equatable, Sendable {
    case session(host: String, user: String?, tmux: String?)
    case workspace(name: String, host: String?)

    public static let scheme = "bsns-ssh"

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, !value.isEmpty, value.count <= 255 else { continue }
            values[item.name.lowercased()] = value
        }
        switch (components.host ?? "").lowercased() {
        case "open":
            guard let host = values["host"] else { return nil }
            self = .session(host: host, user: values["user"], tmux: MoshServerCommand.sanitizedTmuxName(values["tmux"]))
        case "workspace":
            guard let name = values["name"] else { return nil }
            self = .workspace(name: name, host: values["host"])
        default:
            return nil
        }
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case let .session(host, user, tmux):
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "host", value: host)]
                + (user.map { [URLQueryItem(name: "user", value: $0)] } ?? [])
                + (tmux.map { [URLQueryItem(name: "tmux", value: $0)] } ?? [])
        case let .workspace(name, host):
            components.host = "workspace"
            components.queryItems = [URLQueryItem(name: "name", value: name)]
                + (host.map { [URLQueryItem(name: "host", value: $0)] } ?? [])
        }
        return components.url
    }
}
