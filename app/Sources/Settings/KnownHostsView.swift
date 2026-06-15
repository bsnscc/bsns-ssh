import SwiftUI
import BsnsSSHCore

/// View and forget trusted host keys (TOFU fingerprints). Forgetting one means
/// the next connection to that host re-prompts to verify its key, so deletion is
/// confirmed explicitly rather than on a stray swipe.
struct KnownHostsView: View {
    @Environment(KnownHostsStore.self) private var store

    @State private var pendingForget: String?

    private var entries: [(id: String, key: HostKey)] {
        store.knownHosts.allEntries.map { (id: $0.key, key: $0.value) }.sorted { $0.id < $1.id }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Text("No trusted hosts yet. The first time you connect to a host you'll verify and trust its key.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.id).font(.callout.monospaced())
                        Text(entry.key.keyType)
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(entry.key.fingerprint)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                    .swipeActions {
                        Button("Forget", role: .destructive) { pendingForget = entry.id }
                    }
                }
            }
        }
        .navigationTitle("Known Hosts")
        .alert("Forget this host key?", isPresented: Binding(
            get: { pendingForget != nil },
            set: { if !$0 { pendingForget = nil } }
        )) {
            Button("Forget", role: .destructive) {
                if let id = pendingForget { store.forget(id) }
                pendingForget = nil
            }
            Button("Cancel", role: .cancel) { pendingForget = nil }
        } message: {
            if let id = pendingForget {
                Text("""
                \(id)

                The next time you connect you'll be asked to verify and trust this server's key again. Only forget a host if you expect its key to change (e.g. the server was rebuilt).
                """)
            }
        }
    }
}
