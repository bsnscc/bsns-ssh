import SwiftUI
import BsnsSSHCore

/// Pair with an iPhone: pick it from the phones on this network, then compare
/// the six-digit code on both screens.
struct MacPairingSheet: View {
    @Environment(PhoneKeyClient.self) private var phoneKeys
    @Environment(\.dismiss) private var dismiss
    @State private var pairing: PhoneKeyClient.Pairing?
    @State private var busy = false
    @State private var error: String?
    @State private var address = ""

    var body: some View {
        VStack(spacing: 18) {
            if let pairing {
                Text("Does the iPhone show this code?").font(.headline)
                Text(pairing.outcome.code)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .kerning(4)
                Text(pairing.outcome.peer.name.isEmpty ? "iPhone" : pairing.outcome.peer.name).foregroundStyle(.secondary)
                Text("Confirm only if both screens show the same six digits. If they differ, something on the network is between the two devices — cancel.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Cancel", role: .cancel) { finish(pairing, accepted: false) }
                    Button("The Codes Match") { finish(pairing, accepted: true) }
                        .keyboardShortcut(.defaultAction)
                }
                .disabled(busy)
                if busy { ProgressView("Waiting for the iPhone…").controlSize(.small) }
            } else {
                Text("Pair iPhone").font(.headline)
                Text("On the iPhone: bsns.SSH → Settings → Phone as a Key → Pair a Computer.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if phoneKeys.found.isEmpty {
                    ProgressView("Looking for an iPhone nearby…").controlSize(.small)
                } else {
                    ForEach(phoneKeys.found) { phone in
                        Button {
                            begin(phone)
                        } label: {
                            Label("iPhone \(phone.id)", systemImage: "iphone").frame(maxWidth: .infinity)
                        }
                        .disabled(busy)
                    }
                }
                HStack {
                    TextField("Or the phone's address", text: $address, prompt: Text("Not nearby? Its tailnet name or address"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { beginByAddress() }
                    Button("Connect") { beginByAddress() }
                        .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error { Text(error).foregroundStyle(.red).multilineTextAlignment(.center) }
        }
        .padding(26)
        .frame(width: 420)
        .onAppear { phoneKeys.startBrowsing() }
        .onDisappear { phoneKeys.stopBrowsing() }
    }

    private func beginByAddress() {
        guard let first = HostRoutes.parse(address, excluding: "").first else { return }
        begin(.at(first))
    }

    private func begin(_ phone: PhoneKeyClient.Found) {
        busy = true
        error = nil
        Task {
            do { pairing = try await phoneKeys.beginPairing(with: phone) }
            catch let error as PhoneKeyClient.PairingError { self.error = error.localizedDescription }
            catch { self.error = "Couldn't start pairing: \(error.localizedDescription)" }
            busy = false
        }
    }

    private func finish(_ pairing: PhoneKeyClient.Pairing, accepted: Bool) {
        busy = true
        Task {
            do {
                try await phoneKeys.finish(pairing, accepted: accepted)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                self.pairing = nil
            }
            busy = false
        }
    }
}
