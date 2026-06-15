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
    @State private var reviewItem: ReviewItem?
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
                Text("Review what a bundle contains before merging. Trusted host keys and private keys are opt-in.")
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
        .sheet(item: $reviewItem) { item in
            ImportReviewView(bundle: item.bundle) { selection in
                applyImport(item.bundle, selection: selection)
            }
        }
    }

    /// Identifiable wrapper so a decoded bundle can drive `.sheet(item:)` without
    /// adding an `id` to the Codable wire format.
    private struct ReviewItem: Identifiable { let id = UUID(); let bundle: ConfigBundle }

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

    /// Decode the picked file and present the review sheet — nothing is applied
    /// until the user confirms a selection there.
    private func finishImport() {
        guard let data = pendingImport else { return }
        let pass = importPassphrase
        do {
            let bundle = try ConfigService.decode(data, passphrase: pass.isEmpty ? nil : pass)
            reviewItem = ReviewItem(bundle: bundle)
        } catch ConfigCryptoError.badPassphrase {
            set("Wrong passphrase.", error: true)
        } catch {
            set("Import failed: \(error)", error: true)
        }
        pendingImport = nil; importPassphrase = ""
    }

    private func applyImport(_ bundle: ConfigBundle, selection: ConfigService.ImportSelection) {
        Task {
            await ConfigService.apply(bundle, selection: selection, hosts: hosts, knownHosts: knownHosts, agent: agent)
            var parts: [String] = []
            if selection.hosts { parts.append("\(bundle.hosts.count) host(s)") }
            if selection.knownHosts { parts.append("\(bundle.knownHosts.allEntries.count) trusted host(s)") }
            if selection.keys { parts.append("\(bundle.keys?.count ?? 0) key(s)") }
            set("Imported \(parts.isEmpty ? "settings" : parts.joined(separator: ", ")).", error: false)
        }
    }

    private func set(_ message: String, error: Bool) { status = message; statusIsError = error }
}

/// Shows what an import bundle contains and lets the user choose what to apply.
/// Hosts + settings default on; trusted host keys and private keys are opt-in
/// because each weakens a security guarantee (TOFU; key custody).
struct ImportReviewView: View {
    let bundle: ConfigBundle
    let onImport: (ConfigService.ImportSelection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection = ConfigService.ImportSelection()

    private var trustedCount: Int { bundle.knownHosts.allEntries.count }
    private var keyCount: Int { bundle.keys?.count ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Contents") {
                    Toggle("\(bundle.hosts.count) saved host(s)", isOn: $selection.hosts)
                        .disabled(bundle.hosts.isEmpty)
                    Toggle("App settings", isOn: $selection.settings)
                }
                Section {
                    Toggle("\(trustedCount) trusted host key(s)", isOn: $selection.knownHosts)
                        .disabled(trustedCount == 0)
                    Toggle("\(keyCount) private key(s)", isOn: $selection.keys)
                        .disabled(keyCount == 0)
                } header: {
                    Text("Security-sensitive")
                } footer: {
                    Text("Trusted host keys pre-trust those servers, skipping the first-connection verification prompt. Private keys are added to your agent and can sign on your behalf. Only enable these for a bundle you created and trust.")
                }
            }
            .navigationTitle("Review import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { onImport(selection); dismiss() }
                }
            }
        }
    }
}

/// A minimal Data-backed document for `fileExporter`.
struct DataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
