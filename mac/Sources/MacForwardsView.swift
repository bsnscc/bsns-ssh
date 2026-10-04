import SwiftUI

/// A session's port forwards: what is listening on this Mac and where each one
/// leads on the far side. Forwards made by clicking a localhost link in the
/// terminal appear here too.
struct MacForwardsView: View {
    let session: TerminalSession
    @Environment(\.dismiss) private var dismiss
    @State private var listenPort = ""
    @State private var destHost = "localhost"
    @State private var destPort = ""
    @State private var error: String?
    @State private var adding = false

    private var canAdd: Bool { UInt16(listenPort) != nil && !destHost.isEmpty && UInt16(destPort) != nil && !adding }

    var body: some View {
        Form {
            Section("Active") {
                if session.forwards.isEmpty {
                    Text("None. Click a localhost link in the terminal, or add one below.").foregroundStyle(.secondary)
                }
                ForEach(session.forwards) { forward in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("localhost:\(String(forward.listenPort))  →  \(forward.destHost):\(String(forward.destPort))")
                                .font(.callout.monospaced())
                            if let failure = forward.error {
                                Text(failure).font(.caption).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        if forward.error == nil, let url = URL(string: "http://127.0.0.1:\(forward.listenPort)/") {
                            Button("Open") { NSWorkspace.shared.open(url) }
                        }
                        Button(role: .destructive) { session.removeForward(forward.id) } label: { Image(systemName: "trash") }
                            .help("Stop forwarding").accessibilityLabel("Stop forwarding")
                    }
                }
            }
            Section("New Forward") {
                TextField("Local port", text: $listenPort, prompt: Text("8080"))
                TextField("Destination host", text: $destHost)
                TextField("Destination port", text: $destPort, prompt: Text("5432"))
                if let error { Text(error).foregroundStyle(.red) }
            }
            Section {
                HStack {
                    Spacer()
                    if adding { ProgressView().controlSize(.small) }
                    Button("Add Forward") { add() }.disabled(!canAdd)
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            } footer: {
                Text("A forward listens on a port on this Mac and tunnels each connection through the server to the destination, as the server sees it. Over mosh, forwards ride a second SSH connection that is opened for them and closed when the last one goes.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 430)
    }

    private func add() {
        guard let local = UInt16(listenPort), let remote = UInt16(destPort) else { return }
        adding = true
        Task {
            error = await session.addForwardConnecting(listenPort: local, destHost: destHost, destPort: remote)
            if error == nil { listenPort = ""; destPort = "" }
            adding = false
        }
    }
}
