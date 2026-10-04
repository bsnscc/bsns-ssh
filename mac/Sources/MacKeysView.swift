import SwiftUI
import AppKit
import BsnsSSHCore

/// The keys the agent holds: create one, copy its public half to install on a
/// server, or remove it.
struct MacKeysView: View {
    @Environment(AgentStore.self) private var store
    @State private var error: String?
    @State private var deleting: SSHPublicKey?
    @State private var copied: Data?
    @State private var activity = KeyActivityLog.shared
    @Environment(PhoneKeyClient.self) private var phoneKeys
    @State private var links = LinkStore.shared
    @State private var pairingPhone = false

    static func name(of identity: SSHPublicKey, hardware: Bool) -> String {
        let kind: String
        switch identity.algorithm {
        case .ed25519: kind = "Ed25519"
        case .ecdsaP256: kind = hardware ? "Secure Enclave P-256" : "ECDSA P-256"
        case .rsa: kind = "RSA"
        case .ecdsaSK, .ed25519SK: kind = "Security key"
        }
        return identity.comment.isEmpty ? kind : "\(kind) — \(identity.comment)"
    }

    var body: some View {
        Form {
            Section {
                if store.identities.isEmpty {
                    Text("No keys yet.").foregroundStyle(.secondary)
                }
                ForEach(store.identities, id: \.blob) { identity in
                    keyRow(identity)
                }
            } header: {
                Text("Keys")
            }

            Section {
                Button("New Secure Enclave Key") {
                    Task {
                        do { try await store.generateEnclaveKey() }
                        catch { self.error = "Couldn't create a Secure Enclave key: \(error.localizedDescription)" }
                    }
                }
                .disabled(!store.enclaveAvailable)
                Button("New Ed25519 Key") { Task { await store.generateKey(.ed25519) } }
            } header: {
                Text("Create")
            } footer: {
                Text(store.enclaveAvailable
                     ? "A Secure Enclave key never leaves this Mac's hardware and asks for Touch ID (or your password) every time it signs. The Enclave only makes P-256 keys, so it appears on servers as ecdsa-sha2-nistp256. An Ed25519 key is stored in your keychain and can be exported."
                     : "This Mac has no Secure Enclave, so only software keys are available. An Ed25519 key is stored in your keychain.")
            }

            Section {
                if links.paired.isEmpty {
                    Text("No iPhone paired.").foregroundStyle(.secondary)
                }
                ForEach(links.paired) { device in
                    HStack {
                        Image(systemName: "iphone").foregroundStyle(Brand.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.peer.name.isEmpty ? "iPhone" : device.peer.name)
                            Text("\(device.identities.count) key\(device.identities.count == 1 ? "" : "s") · \(device.id)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Refresh Keys") {
                            Task {
                                do { try await phoneKeys.refreshKeys(of: device.id) }
                                catch { self.error = "Couldn't reach \(device.peer.name): \(error.localizedDescription)" }
                            }
                        }
                        Button("Unpair", role: .destructive) { Task { await phoneKeys.unpair(device.id) } }
                    }
                }
                Button("Pair iPhone…") { pairingPhone = true }
            } header: {
                Text("iPhone as a Key")
            } footer: {
                Text("Use the hardware-backed keys on your iPhone from this Mac. In bsns.SSH on the phone, turn on Settings → Phone as a Key and choose Pair a Computer. Each sign-in is then approved on the phone with Face ID. Both devices must be on the same local network, with the app open on the phone.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            Section {
                if activity.events.isEmpty {
                    Text("Nothing yet. Each time a key signs, it is listed here.").foregroundStyle(.secondary)
                }
                ForEach(Array(activity.events.suffix(50).reversed().enumerated()), id: \.offset) { _, event in
                    activityRow(event)
                }
                if !activity.events.isEmpty {
                    Button("Clear Activity", role: .destructive) { activity.clear() }
                }
            } header: {
                Text("Activity")
            } footer: {
                Text("Which key was used, by what, to sign in where. Stored on this Mac only; what was signed is never recorded.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Keys")
        .sheet(isPresented: $pairingPhone) { MacPairingSheet() }
        .confirmationDialog("Delete this key?", isPresented: Binding(get: { deleting != nil },
                                                                     set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { identity in
            Button("Delete", role: .destructive) { Task { await store.deleteKey(identity) } }
            Button("Cancel", role: .cancel) { }
        } message: { identity in
            Text(store.isHardware(identity)
                 ? "A Secure Enclave key can't be recovered once deleted. Servers that trust it will stop accepting this Mac."
                 : "Servers that trust this key will stop accepting this Mac unless you have exported it.")
        }
    }

    private func activityRow(_ event: AgentAuditEvent) -> some View {
        let target = event.host.map { host in event.user.map { "\($0)@\(host)" } ?? host } ?? "an unidentified host"
        let symbol: String, tint: Color
        switch event.outcome {
        case .signed: (symbol, tint) = ("checkmark.circle", .green)
        case .declined: (symbol, tint) = ("hand.raised", .orange)
        case .failed: (symbol, tint) = ("xmark.circle", .red)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(event.requester ?? "bsns.SSH") → \(target)")
                Text("\(event.keyComment.isEmpty ? event.keyFingerprint : event.keyComment) · \(event.outcome.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(event.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func keyRow(_ identity: SSHPublicKey) -> some View {
        let hardware = store.isHardware(identity)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: hardware ? "cpu" : "key")
                .foregroundStyle(hardware ? Brand.accent : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.name(of: identity, hardware: hardware))
                Text(SSHKeyFormat.fingerprint(ofPublicKeyBlob: identity.blob))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(copied == identity.blob ? "Copied" : "Copy Public Key") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(authorizedKeysLine(identity), forType: .string)
                copied = identity.blob
            }
            .help("Copy the authorized_keys line to install on a server")
            Button(role: .destructive) { deleting = identity } label: { Image(systemName: "trash") }
                .help("Delete key")
                .accessibilityLabel("Delete key")
        }
    }
}
