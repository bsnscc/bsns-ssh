import SwiftUI

/// Enroll a YubiKey: enter the PIV PIN, then tap (NFC) or keep it plugged (USB-C)
/// to read its public key and add it as an SSH identity.
struct YubiKeyEnrollView: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var pin = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PIV PIN", text: $pin)
                        .keyboardType(.numberPad).textContentType(.password)
                } footer: {
                    Text("The PIV PIN protects the key on your YubiKey (default 123456). It's kept only in memory for this session.")
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
                try await store.enrollYubiKey(pin: pin)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}
