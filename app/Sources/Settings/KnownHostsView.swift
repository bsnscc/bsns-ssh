import SwiftUI
import BsnsSSHCore

/// View and forget trusted host keys (TOFU fingerprints). Forgetting one means
/// the next connection to that host re-prompts to verify its key.
struct KnownHostsView: View {
    @Environment(KnownHostsStore.self) private var store

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
                        Text("\(entry.key.keyType)  ·  \(entry.key.fingerprint)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .onDelete { offsets in
                    let ids = entries.map(\.id)
                    offsets.map { ids[$0] }.forEach(store.forget)
                }
            }
        }
        .navigationTitle("Known Hosts")
        .toolbar { if !entries.isEmpty { EditButton() } }
    }
}
