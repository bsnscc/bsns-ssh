import SwiftUI
import UniformTypeIdentifiers
import BsnsSSHCore

/// A minimal SFTP file browser over one host: navigate folders, download files,
/// upload, make folders, delete. Authenticates through the agent (same as the
/// shell) and runs the first-connection host-key prompt inline.
struct SFTPBrowserView: View {
    let host: String
    let port: UInt16
    let user: String
    var keyBlob: Data? = nil

    @Environment(AgentStore.self) private var store
    @Environment(KnownHostsStore.self) private var knownHostsStore
    @Environment(\.dismiss) private var dismiss

    @State private var client = SFTPClient()
    @State private var path = "."
    @State private var entries: [SFTPEntry] = []
    @State private var stack: [String] = []        // parent paths for "up"
    @State private var connected = false
    @State private var busy = false
    @State private var error: String?
    @State private var pendingHostKey: HostKey?
    @State private var pendingDelete: SFTPEntry?

    @State private var showUpload = false
    @State private var newFolderName = ""
    @State private var askNewFolder = false
    @State private var exportFileURL: URL?       // a streamed-to temp file, exported via fileMover
    @State private var showExport = false

    var body: some View {
        NavigationStack {
            List {
                if busy && entries.isEmpty {
                    HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) }
                }
                ForEach(entries) { entry in
                    Button { open(entry) } label: {
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                            Text(entry.name).foregroundStyle(.primary)
                            Spacer()
                            if entry.isDirectory {
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            } else {
                                Text(byteSize(entry.size)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { pendingDelete = entry }
                        if !entry.isDirectory {
                            Button("Download") { download(entry) }.tint(.blue)
                        }
                    }
                }
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            .navigationTitle(path == "." ? "~" : (path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if stack.isEmpty {
                        Button("Done") { client.disconnect(); dismiss() }
                    } else {
                        Button { goUp() } label: { Label("Up", systemImage: "chevron.up") }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { askNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                        .disabled(!connected)
                        .accessibilityLabel("New folder")
                    Button { showUpload = true } label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(!connected)
                        .accessibilityLabel("Upload file")
                }
            }
        }
        .task { await connect() }
        .alert("Verify host key", isPresented: Binding(get: { pendingHostKey != nil }, set: { if !$0 { pendingHostKey = nil } })) {
            Button("Trust", role: .destructive) { trustAndConnect() }
            Button("Cancel", role: .cancel) { pendingHostKey = nil; dismiss() }
        } message: {
            if let key = pendingHostKey {
                Text("First connection to \(user)@\(host):\(port).\n\n\(key.keyType)\n\(key.fingerprint)\n\nOnly trust this if the fingerprint matches what the server's admin gave you.")
            }
        }
        .alert("Delete \(pendingDelete?.name ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { entry in
            Button("Delete", role: .destructive) { remove(entry); pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { entry in
            Text(entry.isDirectory ? "Deletes this folder on the server." : "Deletes this file on the server.")
        }
        .alert("New folder", isPresented: $askNewFolder) {
            TextField("name", text: $newFolderName)
            Button("Create") { makeFolder() }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .fileImporter(isPresented: $showUpload, allowedContentTypes: [.data, .item]) { result in
            if case .success(let url) = result { upload(url) }
        }
        // Move the streamed-to temp file to the user's chosen location — no
        // in-memory Data, so a large download won't OOM.
        .fileMover(isPresented: $showExport, file: exportFileURL) { _ in
            if let u = exportFileURL { try? FileManager.default.removeItem(at: u) }
            exportFileURL = nil
        }
    }

    // MARK: actions

    private func connect() async {
        guard !connected, !busy else { return }
        busy = true; error = nil
        do {
            try await client.connect(host: host, port: port, user: user,
                                     agent: store.agent, knownHosts: knownHostsStore.knownHosts,
                                     keyBlob: keyBlob)
            connected = true
            await reload()
        } catch SSHShellError.unknownHostKey(let key) {
            pendingHostKey = key
        } catch {
            self.error = TerminalSession.describe(error)
        }
        busy = false
    }

    private func trustAndConnect() {
        guard let key = pendingHostKey else { return }
        knownHostsStore.trust(host: host, port: port, key: key)
        pendingHostKey = nil
        Task { await connect() }
    }

    private func reload() async {
        do { entries = try await client.list(path) }
        catch { self.error = TerminalSession.describe(error) }
    }

    private func open(_ entry: SFTPEntry) {
        guard entry.isDirectory else { download(entry); return }
        stack.append(path)
        path = path == "." ? entry.name : "\(path)/\(entry.name)"
        Task { await reload() }
    }

    private func goUp() {
        guard let parent = stack.popLast() else { return }
        path = parent
        Task { await reload() }
    }

    private func childPath(_ name: String) -> String { path == "." ? name : "\(path)/\(name)" }

    private func download(_ entry: SFTPEntry) {
        Task {
            do {
                // Stream to a temp file, then hand it to the system file mover.
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
                try? FileManager.default.removeItem(at: tmp)
                try await client.download(childPath(entry.name), toFile: tmp)
                exportFileURL = tmp
                showExport = true
            } catch { self.error = TerminalSession.describe(error) }
        }
    }

    private func upload(_ url: URL) {
        // Hold security-scoped access across the whole streaming read (the Task's
        // defer fires after the upload completes, not before the await).
        let scoped = url.startAccessingSecurityScopedResource()
        let name = url.lastPathComponent
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try await client.upload(fromFile: url, to: childPath(name)); await reload() }
            catch { self.error = TerminalSession.describe(error) }
        }
    }

    private func makeFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        newFolderName = ""
        guard !name.isEmpty else { return }
        Task {
            do { try await client.makeDirectory(childPath(name)); await reload() }
            catch { self.error = TerminalSession.describe(error) }
        }
    }

    private func remove(_ entry: SFTPEntry) {
        Task {
            do { try await client.remove(childPath(entry.name), isDirectory: entry.isDirectory); await reload() }
            catch { self.error = TerminalSession.describe(error) }
        }
    }

    private func byteSize(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
