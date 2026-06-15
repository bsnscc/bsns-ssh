import SwiftUI

/// Manage a session's local (-L) port forwards: each listens on this device and
/// tunnels connections to a host reachable from the SSH server.
struct PortForwardsView: View {
    let session: TerminalSession
    @Environment(\.dismiss) private var dismiss

    @State private var listenPort = ""
    @State private var destHost = "127.0.0.1"
    @State private var destPort = ""
    @State private var error: String?

    private var canAdd: Bool {
        UInt16(listenPort) != nil && !destHost.isEmpty && UInt16(destPort) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Listen on a port on this device and tunnel each connection through the server to the destination — e.g. reach a database or web UI that only the server can see.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !session.forwards.isEmpty {
                    Section("Active") {
                        ForEach(session.forwards) { f in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("localhost:\(f.listenPort)  →  \(f.destHost):\(f.destPort)")
                                    .font(.callout.monospaced())
                                if let e = f.error {
                                    Text(e).font(.caption).foregroundStyle(.red)
                                } else {
                                    Label("listening", systemImage: "dot.radiowaves.left.and.right")
                                        .font(.caption).foregroundStyle(.green)
                                }
                            }
                        }
                        .onDelete { idx in idx.map { session.forwards[$0].id }.forEach(session.removeForward) }
                    }
                }

                Section("New forward") {
                    TextField("local port — e.g. 8080", text: $listenPort)
                        .keyboardType(.numberPad)
                    TextField("destination host — e.g. 127.0.0.1", text: $destHost)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("destination port — e.g. 5432", text: $destPort)
                        .keyboardType(.numberPad)
                    Button("Add forward") { add() }.disabled(!canAdd)
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("Port Forwarding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func add() {
        guard let lp = UInt16(listenPort), let dp = UInt16(destPort), !destHost.isEmpty else { return }
        error = session.addForward(listenPort: lp, destHost: destHost, destPort: dp)
        if error == nil { listenPort = ""; destPort = "" }
    }
}
