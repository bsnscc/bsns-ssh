import SwiftUI
import UniformTypeIdentifiers
import BsnsSSHCore

/// Migrate an existing OpenSSH setup: pick a `config`, `known_hosts`, or private
/// key file from the Files app and merge it in. Everything is additive and the
/// hosts are previewed before import; nothing leaves the device. Parsing lives
/// in `BsnsSSHCore` (shared, unit-tested).
struct ImportConfigView: View {
    @Environment(HostStore.self) private var hostStore
    @Environment(KnownHostsStore.self) private var knownHostsStore
    @Environment(AgentStore.self) private var agentStore
    @Environment(\.dismiss) private var dismiss

    private enum Picking { case config, knownHosts, key }
    @State private var picking: Picking?
    @State private var status: String?
    @State private var pendingHosts: [SSHConfigHost]?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Bring over an existing setup. Pick the files from ~/.ssh — nothing leaves "
                         + "your device, and everything is added alongside what you already have.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("ssh config") {
                    Button("Import an ssh config") { picking = .config }
                    Text("Reads Host blocks (HostName, Port, User, ProxyJump) into your saved hosts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("known_hosts") {
                    Button("Import known_hosts") { picking = .knownHosts }
                    Text("Trusts the host keys you already accepted. Hashed (anonymized) entries can't be recovered and are skipped.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Private key") {
                    Button("Import a private key") { picking = .key }
                    Text("Unencrypted ed25519, ecdsa-p256, or RSA keys — OpenSSH format, or RSA in PKCS#1/PKCS#8 PEM. Decrypt a passphrase-protected key first (ssh-keygen -p).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let status {
                    Section { Text(status).foregroundStyle(.green).font(.callout) }
                }
            }
            .navigationTitle("Import from OpenSSH")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                          allowedContentTypes: [.data, .item, .plainText],
                          allowsMultipleSelection: false) { result in
                handlePick(result)
            }
            .alert("Import \(pendingHosts?.count ?? 0) host(s)?",
                   isPresented: Binding(get: { pendingHosts != nil }, set: { if !$0 { pendingHosts = nil } })) {
                Button("Import") { confirmHosts() }
                Button("Cancel", role: .cancel) { pendingHosts = nil }
            } message: {
                if let hosts = pendingHosts {
                    Text(hosts.map { h in
                        let who = h.user.map { "\($0)@" } ?? ""
                        let port = h.port == 22 ? "" : ":\(h.port)"
                        let via = h.proxyJump.map { "  via \($0)" } ?? ""
                        return "\(who)\(h.hostName)\(port)\(via)"
                    }.joined(separator: "\n"))
                }
            }
        }
    }

    private func readText(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        let kind = picking
        guard case let .success(urls) = result, let url = urls.first, let text = readText(url) else {
            status = "couldn't read that file"; return
        }
        switch kind {
        case .config:
            let hosts = SSHConfigParser.parse(text)
            if hosts.isEmpty { status = "no hosts found in that file" } else { pendingHosts = hosts }
        case .knownHosts:
            let n = knownHostsStore.importEntries(KnownHostsParser.parse(text))
            status = n > 0 ? "trusted \(n) host key(s)" : "no usable host keys (hashed entries can't be imported)"
        case .key:
            do {
                let k = try PrivateKeyImport.parse(text)
                let fileKey = try FileKey.from(algorithm: k.algorithm, privateKeyMaterial: k.material, comment: k.comment)
                Task { await agentStore.importKey(fileKey) }
                status = "imported a \(k.algorithm.rawValue.replacingOccurrences(of: "ssh-", with: "")) key"
            } catch KeyImportError.encrypted {
                status = "the key is passphrase-encrypted — decrypt it first (ssh-keygen -p)"
            } catch KeyImportError.unsupportedType(let t) {
                status = "unsupported key type: \(t)"
            } catch {
                status = "couldn't import that key"
            }
        case nil:
            break
        }
    }

    private func confirmHosts() {
        guard let hosts = pendingHosts else { return }
        let n = hostStore.importConfig(hosts)
        pendingHosts = nil
        status = "imported \(n) host(s)"
    }
}
