#if os(iOS)
import SwiftUI
import BsnsSSHCore

/// Settings for lending this phone's keys to a computer.
struct PhoneKeyView: View {
    @State private var server = PhoneKeyServer.shared
    @State private var store = LinkStore.shared
    @AppStorage(PhoneKeyServer.enabledKey) private var enabled = false
    @State private var pairing = false

    var body: some View {
        Form {
            Section {
                Toggle("Let paired computers use this phone's keys", isOn: $enabled)
                if enabled {
                    switch server.state {
                    case .listening:
                        Label("Available to nearby computers", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                        if server.reachableByAddress {
                            Text("From another network — over a private network such as a tailnet — give the computer this phone's address on that network.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .failed(let message): Text(message).foregroundStyle(.red)
                    case .off: EmptyView()
                    }
                }
            } footer: {
                Text("A paired computer can ask this phone to sign in to a server with one of its hardware-backed keys. Every request is approved here with Face ID, and the prompt says which program on which computer is asking, and for where. It works directly between the two devices — on the same network, nearby without one, or across a private network of your own — only while this app is open, and only for computers you have paired. The keys themselves never leave the phone.")
            }
            .onChange(of: enabled) { _, _ in server.refresh() }

            Section("Paired Computers") {
                if store.paired.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(store.paired) { device in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.peer.name.isEmpty ? "Computer" : device.peer.name)
                        Text(device.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in offsets.map { store.paired[$0].id }.forEach(store.remove) }
                Button("Pair a Computer…") { pairing = true }
                    .disabled(!enabled)
            }
        }
        .navigationTitle("Phone as a Key")
        .sheet(isPresented: $pairing) { PairingSheet() }
    }
}

private struct PairingSheet: View {
    @State private var server = PhoneKeyServer.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                if let pending = server.pendingPairing {
                    Text("Does the computer show this code?").font(.headline)
                    Text(pending.outcome.code)
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .kerning(4)
                    Text(pending.outcome.peer.name.isEmpty ? "A computer" : pending.outcome.peer.name)
                        .foregroundStyle(.secondary)
                    Text("Confirm only if both screens show the same six digits. If they differ, something on the network is between the two devices — cancel.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("The Codes Match") { server.decidePairing(true); dismiss() }
                        .buttonStyle(BrandButtonStyle())
                    Button("Cancel", role: .cancel) { server.decidePairing(false); dismiss() }
                } else {
                    ProgressView()
                    Text("Waiting for a computer").font(.headline)
                    Text("On the computer, open bsns.SSH, go to Keys and choose Pair iPhone. The two devices need to be near each other or on the same network.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(28)
            .navigationTitle("Pair a Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { server.decidePairing(false); dismiss() }
                }
            }
        }
        .onAppear { server.acceptsPairing = true }
        .onDisappear { server.acceptsPairing = false }
    }
}
#endif
