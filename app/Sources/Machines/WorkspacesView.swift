import SwiftUI
import BsnsSSHCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The user's projects, and for each the machines that have it: how busy each
/// machine is, what state the project is in there, and a button to open it —
/// on a chosen machine, or on whichever has the most room.
struct WorkspacesView: View {
    @Environment(MachineBoard.self) private var board
    @Environment(HostStore.self) private var hosts
    @Environment(AgentStore.self) private var store
    @Environment(KnownHostsStore.self) private var knownHosts
    @Environment(SessionStore.self) private var sessions
    @Environment(PlatformSurfaceCache.self) private var surfaces
    @State private var workspaces = WorkspaceStore.shared
    @State private var statuses: [String: WorkspaceStatus] = [:]
    @State private var editing: Workspace?
    @State private var copied: UUID?

    /// One machine a workspace is on.
    private struct Place: Identifiable {
        let machine: MachineBoard.Machine
        var id: String { machine.id }
    }

    var body: some View {
        List {
            if workspaces.workspaces.isEmpty {
                Section {
                    Text("A workspace is a project you work on from more than one machine: one repository, at a path on each. Opening it attaches the same tmux session wherever you are, so the work is always under one name.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(workspaces.workspaces) { workspace in
                Section {
                    let places = places(of: workspace)
                    if places.isEmpty {
                        Text("None of its machines are saved on this device. Edit the workspace to choose where it lives.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(places) { place in row(workspace, at: place.machine) }
                } header: {
                    header(of: workspace)
                }
            }
            Section {
                Button("New Workspace…") {
                    editing = Workspace(name: "", path: "~/", hosts: [])
                }
            }
        }
        .navigationTitle("Workspaces")
        .sheet(item: $editing) { workspace in
            WorkspaceEditor(workspace: workspace, savedHosts: hosts.hosts.map(\.host),
                            isNew: !workspaces.workspaces.contains { $0.id == workspace.id })
        }
        .task(id: refreshKey) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    /// Re-read states when the set of workspaces or of live machines changes.
    private var refreshKey: String {
        workspaces.workspaces.map { "\($0.id)\($0.path)\($0.statusCommand ?? "")" }.joined()
            + board.machines.filter { $0.state == .live }.map(\.id).joined()
    }

    // MARK: rows

    @ViewBuilder private func header(of workspace: Workspace) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
            Text(workspace.name).font(.headline)
            Text(workspace.path).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
            if let best = leastBusy(for: workspace) {
                Button("Open Where There's Room") { open(workspace, at: best) }
                    .controlSize(.small)
                    .help("Opens on \(best.name), which has the lowest load for its size right now")
            }
            Button(copied == workspace.id ? "Copied" : "Copy Link") {
                guard let url = DeepLink.workspace(name: workspace.name, host: nil).url else { return }
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                #else
                UIPasteboard.general.string = url.absoluteString
                #endif
                copied = workspace.id
            }
            .controlSize(.small)
            .help("A link that opens this workspace — for a script, a note or a notification")
            Button("Edit…") { editing = workspace }.controlSize(.small)
        }
    }

    private func row(_ workspace: Workspace, at machine: MachineBoard.Machine) -> some View {
        let status = statuses[key(workspace, machine)]
        let watched = machine.isLocal || machine.state == .live
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: machine.isLocal ? "laptopcomputer" : "network")
                .foregroundStyle(machine.isLocal ? Brand.accent : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(machine.name)
                    if let overview = machine.overview, let load = overview.load.first {
                        Text("load \(String(format: "%.1f", load))\(overview.cpus.map { " on \($0) cores" } ?? "")")
                            .font(.caption).foregroundStyle(load > Double(overview.cpus ?? 8) ? .orange : .secondary)
                    }
                }
                if let status {
                    Text(status.summary).font(.caption).foregroundStyle(status.exists ? .secondary : Color.orange)
                    ForEach(status.statusLines, id: \.self) { line in
                        Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else if !watched {
                    Text(machine.state == .connecting ? "Connecting…" : "Watch this machine to see the project's state there.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !watched, machine.state != .connecting, let host = machine.host {
                Button("Watch") {
                    AttentionNotifier.shared.prepare()
                    board.watch(machine.id, agent: store.agent, knownHosts: knownHosts.knownHosts,
                                keyBlob: SessionOpener.key(for: host, store: store))
                }
                .controlSize(.small)
            }
            Button("Open") { open(workspace, at: machine) }
                .controlSize(.small)
                .disabled(workspace.tmuxSession == nil || status?.exists == false)
        }
    }

    // MARK: data

    private func key(_ workspace: Workspace, _ machine: MachineBoard.Machine) -> String { "\(workspace.id)/\(machine.id)" }

    /// The machines a workspace is on, as this Mac sees them: itself when the
    /// path exists here, and each saved host the workspace lists.
    private func places(of workspace: Workspace) -> [Place] {
        board.machines.compactMap { machine in
            if let host = machine.host {
                return workspace.includes(host: host.host) && !isThisMac(host) ? Place(machine: machine) : nil
            }
            return existsHere(workspace) ? Place(machine: machine) : nil
        }
    }

    private func existsHere(_ workspace: Workspace) -> Bool {
        #if !os(macOS)
        return false   // nothing runs on a phone or tablet itself
        #else
        var isDirectory: ObjCBool = false
        let path = (workspace.path(on: nil) as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        #endif
    }

    /// A saved host that is this very Mac (a workspace synced from the other
    /// machine lists it) is shown once, as the local row.
    private func isThisMac(_ host: SavedHost) -> Bool {
        #if !os(macOS)
        return false
        #else
        let mine = ProcessInfo.processInfo.hostName.lowercased()
        let short = mine.split(separator: ".").first.map(String.init) ?? mine
        return ([host.host] + (host.routes ?? [])).contains { name in
            let name = name.lowercased()
            return name == mine || name == short || name == short + ".local"
        }
        #endif
    }

    private func leastBusy(for workspace: Workspace) -> MachineBoard.Machine? {
        let candidates = places(of: workspace).map(\.machine)
            .filter { ($0.isLocal || $0.state == .live) && statuses[key(workspace, $0)]?.exists != false }
        guard candidates.count > 1 else { return nil }
        let best = WorkspaceCommand.leastBusy(candidates.map { (id: $0.id, load: $0.overview?.load.first, cpus: $0.overview?.cpus) })
        return candidates.first { $0.id == best }
    }

    private func refresh() async {
        for workspace in workspaces.workspaces {
            for place in places(of: workspace) {
                let machine = place.machine
                guard machine.isLocal || machine.state == .live,
                      let command = WorkspaceCommand.status(path: workspace.path(on: machine.host?.host),
                                                            statusCommand: workspace.statusCommand),
                      let output = await board.run(command, on: machine.id),
                      let status = WorkspaceCommand.parseStatus(output) else { continue }
                statuses[key(workspace, machine)] = status
            }
        }
    }

    private func open(_ workspace: Workspace, at machine: MachineBoard.Machine) {
        guard let session = workspace.tmuxSession else { return }
        if let host = machine.host {
            SessionOpener.open(workspace, on: host, sessions: sessions, store: store, knownHosts: knownHosts)
        } else {
            #if os(macOS)
            let title = "\(workspace.name) · This Mac"
            if let existing = sessions.sessions.first(where: { $0.title == title }) {
                sessions.activate(existing)
                return
            }
            let prepare = WorkspaceCommand.prepare(workspace).map { $0 + " && " } ?? ""
            LocalShellLauncher.open(sessions: sessions, surfaces: surfaces, store: store,
                                    command: prepare + "exec " + MoshServerCommand.attachCommand(session, directory: workspace.path(on: nil)),
                                    title: title)
            #endif
        }
    }
}

private struct WorkspaceEditor: View {
    @State var workspace: Workspace
    let savedHosts: [String]
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    private func updateWindow(_ id: UUID, change: (inout WorkspaceWindow) -> Void) {
        guard let index = workspace.windows?.firstIndex(where: { $0.id == id }),
              var window = workspace.windows?[index] else { return }
        change(&window)
        workspace.windows?[index] = window
    }

    private var valid: Bool {
        workspace.tmuxSession != nil && WorkspaceCommand.quoted(workspace.path) != nil
            && WorkspaceCommand.isUsable(statusCommand: workspace.statusCommand ?? "")
            && ((workspace.windows ?? []).isEmpty || WorkspaceCommand.prepare(workspace) != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Workspace" : "Edit Workspace").font(.headline)
            Form {
                TextField("Name", text: $workspace.name, prompt: Text("site"))
                TextField("Path", text: $workspace.path, prompt: Text("~/work/site — the same on every machine"))
                TextField("Tmux session", text: Binding(get: { workspace.sessionName ?? "" },
                                                        set: { workspace.sessionName = $0.isEmpty ? nil : $0 }),
                          prompt: Text("Defaults to the workspace name"))
                TextField("Repository", text: Binding(get: { workspace.repository ?? "" },
                                                      set: { workspace.repository = $0.isEmpty ? nil : $0 }),
                          prompt: Text("optional — its remote, for reference"))
                TextField("Status command", text: Binding(get: { workspace.statusCommand ?? "" },
                                                          set: { workspace.statusCommand = $0.isEmpty ? nil : $0 }),
                          prompt: Text("optional — run in the project directory on each machine"))
            }
            Text("Saved windows").font(.subheadline.weight(.medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(workspace.windows ?? []) { window in
                        VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(window.index)").monospacedDigit().frame(width: 24)
                            TextField("Window name", text: Binding(
                                get: { workspace.windows?.first(where: { $0.id == window.id })?.name ?? "" },
                                set: { value in updateWindow(window.id) { $0.name = value } }))
                            // A label only — what it runs is defined on each host.
                            TextField("Tool", text: Binding(
                                get: { workspace.windows?.first(where: { $0.id == window.id })?.tool ?? "" },
                                set: { value in
                                    let label = String(value.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
                                        .prefix(WorkspaceWindow.maxToolLength))
                                    updateWindow(window.id) { $0.tool = label.isEmpty ? nil : label }
                                }), prompt: Text("shell"))
                                .frame(maxWidth: 110)
                                .help("Optional label, such as editor or review. Each host defines what a label runs; a window without one is a plain shell.")
                            Button { workspace.windows?.removeAll { $0.id == window.id } } label: {
                                Image(systemName: "minus.circle")
                            }.accessibilityLabel("Remove \(window.name) from saved layout")
                        }
                        TextField("Directory (defaults to workspace)", text: Binding(
                            get: { workspace.windows?.first(where: { $0.id == window.id })?.directory ?? "" },
                            set: { value in updateWindow(window.id) { $0.directory = value.isEmpty ? nil : value } }))
                            .font(.caption)
                        }
                    }
                    Button("Add Window") {
                        let index = (workspace.windows?.map(\.index).max() ?? -1) + 1
                        if workspace.windows == nil { workspace.windows = [] }
                        workspace.windows?.append(WorkspaceWindow(index: index, name: "shell-\(index)"))
                    }
                }
            }.frame(maxHeight: 180)
            Text("Names use letters, numbers, hyphens or underscores. Saved windows open full-screen on every device. The host restores missing windows without restarting running work. Agent conversations resume when you run dev resume in that window.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let name = workspace.tmuxSession {
                Text("Opens the tmux session “\(name)” on whichever machine you choose, creating it in the project directory the first time.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if WorkspaceCommand.quoted(workspace.path) == nil {
                Text("The path must be absolute or start with ~/, without quotes, $ or backslashes.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("On these machines").font(.subheadline.weight(.medium))
            if savedHosts.isEmpty {
                Text("Save a host under Connect to add another machine. This Mac counts when the path exists here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(savedHosts, id: \.self) { host in
                Toggle(host, isOn: Binding(
                    get: { workspace.includes(host: host) },
                    set: { on in
                        workspace.hosts.removeAll { $0.caseInsensitiveCompare(host) == .orderedSame }
                        if on { workspace.hosts.append(host) }
                    }))
            }
            Text("The status command is not carried to your other devices by sync; enter it on each, so nothing arriving from a synced file can run a command for you.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        WorkspaceStore.shared.remove(workspace.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    workspace.name = workspace.name.trimmingCharacters(in: .whitespaces)
                    WorkspaceStore.shared.upsert(workspace)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(width: 520)
        #endif
    }
}
