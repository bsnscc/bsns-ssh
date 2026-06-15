import SwiftUI
import BsnsSSHCore

struct KeysView: View {
    @Environment(AgentStore.self) private var store

    var body: some View {
        List {
            Section("Keys in the agent") {
                if store.identities.isEmpty {
                    Text("No keys yet — generate one below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.identities, id: \.blob) { key in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(key.algorithm.rawValue)
                            .font(.headline)
                        Text(SSHKeyFormat.fingerprint(ofPublicKeyBlob: key.blob))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !key.comment.isEmpty {
                            Text(key.comment)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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
        }
        .navigationTitle("Keys")
        .task { await store.refresh() }
    }
}
