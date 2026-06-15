import SwiftUI
import BsnsSSHCore

struct ConnectView: View {
    @Environment(AgentStore.self) private var store
    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var connecting = false
    @State private var error: String?
    @State private var activeShell: SSHShell?
    @State private var showTerminal = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("host", text: $host)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("port", text: $port)
                    .keyboardType(.numberPad)
                TextField("user", text: $user)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Section("Key") {
                if store.identities.isEmpty {
                    Text("Generate a key on the Keys tab first.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(store.identities.count) agent key(s) will be offered.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(connecting ? "Connecting…" : "Connect") { connect() }
                    .disabled(connecting || host.isEmpty || user.isEmpty || store.identities.isEmpty)
            }

            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
        }
        .navigationTitle("Connect")
        .navigationDestination(isPresented: $showTerminal) {
            if let activeShell {
                LiveTerminalScreen(shell: activeShell, title: "\(user)@\(host)")
            }
        }
    }

    private func connect() {
        guard let portValue = UInt16(port) else { error = "Invalid port."; return }
        error = nil
        connecting = true
        let shell = SSHShell()
        Task {
            do {
                try await shell.connect(host: host, port: portValue, user: user, agent: store.agent)
                await MainActor.run {
                    connecting = false
                    activeShell = shell
                    showTerminal = true
                }
            } catch {
                await MainActor.run {
                    connecting = false
                    self.error = "\(error)"
                }
            }
        }
    }
}
