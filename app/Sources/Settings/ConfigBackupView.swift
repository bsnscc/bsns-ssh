import SwiftUI
import UniformTypeIdentifiers

/// Export the app's configuration to a JSON file (optionally encrypted with a
/// passphrase) and import one back. Software private keys are only ever included
/// when the user opts in, and only inside an encrypted bundle.
struct ConfigBackupView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KnownHostsStore.self) private var knownHosts
    @Environment(AgentStore.self) private var agent

    @State private var passphrase = ""
    @State private var includeKeys = false
    @State private var exportData: Data?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var pendingImport: Data?
    @State private var importPassphrase = ""
    @State private var askImportPassphrase = false
    @State private var status: String?
    @State private var statusIsError = false

    var body: some View {
        Form {
            Section {
                SecureField("Passphrase (optional)", text: $passphrase)
                    .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
                Toggle("Also export encrypted private keys", isOn: $includeKeys)
                    .disabled(passphrase.isEmpty)
                Button("Export…") { startExport() }
            } header: {
                Text("Export")
            } footer: {
                Text(passphrase.isEmpty
                     ? "Without a passphrase the file is plain JSON (hosts, settings, trusted hosts). Set one to encrypt; only then can private keys be included."
                     : "Encrypted with your passphrase (AES-256-GCM). Keep it safe — it can't be recovered.")
            }

            Section {
                Button("Import…") { showImporter = true }
            } header: {
                Text("Import")
            } footer: {
                Text("Merges hosts, settings, and trusted hosts from a bundle. Existing entries are kept.")
            }

            if let status {
                Section { Text(status).font(.callout).foregroundStyle(statusIsError ? .red : .green) }
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $showExporter,
                      document: DataDocument(data: exportData ?? Data()),
                      contentType: .json,
                      defaultFilename: "bsns-config") { result in
            switch result {
            case .success: set("Exported.", error: false)
            case .failure(let e): set("Export failed: \(e.localizedDescription)", error: true)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .data]) { result in
            handlePicked(result)
        }
        .alert("Encrypted bundle", isPresented: $askImportPassphrase) {
            SecureField("Passphrase", text: $importPassphrase)
            Button("Import") { finishImport() }
            Button("Cancel", role: .cancel) { pendingImport = nil; importPassphrase = "" }
        } message: {
            Text("Enter the passphrase used to encrypt this file.")
        }
    }

    private func startExport() {
        do {
            exportData = try ConfigService.export(hosts: hosts, knownHosts: knownHosts, agent: agent,
                                                  includeKeys: includeKeys && !passphrase.isEmpty,
                                                  passphrase: passphrase.isEmpty ? nil : passphrase)
            showExporter = true
        } catch {
            set("Export failed: \(error)", error: true)
        }
    }

    private func handlePicked(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { set("Couldn't read the file.", error: true); return }
        switch ConfigService.inspect(data) {
        case .encrypted:
            pendingImport = data; importPassphrase = ""; askImportPassphrase = true
        case .plain:
            pendingImport = data; finishImport()
        }
    }

    private func finishImport() {
        guard let data = pendingImport else { return }
        let pass = importPassphrase
        Task {
            do {
                let bundle = try ConfigService.decode(data, passphrase: pass.isEmpty ? nil : pass)
                await ConfigService.apply(bundle, hosts: hosts, knownHosts: knownHosts, agent: agent)
                let n = bundle.keys?.count ?? 0
                set("Imported \(bundle.hosts.count) host(s)\(n > 0 ? ", \(n) key(s)" : "").", error: false)
            } catch ConfigCryptoError.badPassphrase {
                set("Wrong passphrase.", error: true)
            } catch {
                set("Import failed: \(error)", error: true)
            }
            pendingImport = nil; importPassphrase = ""
        }
    }

    private func set(_ message: String, error: Bool) { status = message; statusIsError = error }
}

/// A minimal Data-backed document for `fileExporter`.
struct DataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
