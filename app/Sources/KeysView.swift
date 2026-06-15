import SwiftUI
import UIKit
import BsnsSSHCore

struct KeysView: View {
    @Environment(AgentStore.self) private var store
    @State private var copied: String?

    var body: some View {
        List {
            Section("Keys in the agent") {
                if store.identities.isEmpty {
                    Text("No keys yet — generate one below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.identities, id: \.blob) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key.algorithm.rawValue)
                            .font(.headline)
                        Text(SSHKeyFormat.fingerprint(ofPublicKeyBlob: key.blob))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(authorizedKeysLine(key))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        HStack(spacing: 16) {
                            Button {
                                UIPasteboard.general.string = authorizedKeysLine(key)
                                copied = key.blob.base64EncodedString()
                            } label: {
                                Label(copied == key.blob.base64EncodedString() ? "Copied!" : "Copy public key",
                                      systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            ShareLink(item: authorizedKeysLine(key)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.caption)
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    let targets = offsets.map { store.identities[$0] }
                    Task { for identity in targets { await store.deleteKey(identity) } }
                }
            }

            Section("Generate") {
                Button("Ed25519 (software key)") {
                    Task { await store.generateKey(.ed25519) }
                }
                Button("ECDSA P-256 (software key)") {
                    Task { await store.generateKey(.ecdsaP256) }
                }
            }

            Section {
                Text("Add a key to a server with **ssh-copy-id** on the Connect tab, or copy the line above into the server's `~/.ssh/authorized_keys`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Keys")
        .task { await store.refresh() }
    }
}
