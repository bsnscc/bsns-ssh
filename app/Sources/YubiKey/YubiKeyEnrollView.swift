import SwiftUI

/// Enroll a YubiKey: enter the PIV PIN, then tap (NFC) or keep it plugged (USB-C)
/// to read its public key and add it as an SSH identity.
struct YubiKeyEnrollView: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var pin = ""
    @State private var managementKey = ""
    @State private var revealManagementKey = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PIV user PIN", text: $pin)
                        .keyboardType(.numberPad).textContentType(.password)
                } footer: {
                    Text("The PIV user PIN (default 123456) authorizes signing. It's kept only in memory for this session. (Not the PUK or the management key.)")
                }
                Section {
                    HStack {
                        // Obscured by default like the PIN (it's a secret), with a
                        // reveal toggle since a long hex key is error-prone to type blind.
                        Group {
                            if revealManagementKey {
                                TextField("Management key (hex) — only if changed", text: $managementKey)
                            } else {
                                SecureField("Management key (hex) — only if changed", text: $managementKey)
                            }
                        }
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                        Button { revealManagementKey.toggle() } label: {
                            Image(systemName: revealManagementKey ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(revealManagementKey ? "Hide management key" : "Show management key")
                    }
                } footer: {
                    Text("Only needed to create a new key on the YubiKey, and only if you've changed the PIV management key from its default (010203…08). Leave blank otherwise.")
                }
                Section {
                    Button(busy ? "Waiting for YubiKey…" : "Connect") { enroll() }
                        .disabled(busy || pin.isEmpty)
                } footer: {
                    Text("If a YubiKey is plugged into USB-C it's used directly; otherwise hold it to the top of your phone to tap over NFC.")
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.callout) } }
            }
            .navigationTitle("Add YubiKey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func enroll() {
        error = nil; busy = true
        Task {
            do {
                try await store.enrollYubiKey(pin: pin, managementKeyHex: managementKey.isEmpty ? nil : managementKey)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}
