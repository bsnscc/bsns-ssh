import SwiftUI
import UIKit
import BsnsSSHCore

struct KeysView: View {
    @Environment(AgentStore.self) private var store
    @State private var copied: String?
    @State private var genError: String?
    @State private var installTarget: InstallTarget?
    @State private var showYubiKey = false
    @State private var showEnclaveBackupWarning = false
    @State private var showFidoEnroll = false
    @State private var fidoName = "bsns"
    @State private var fidoPin = ""
    /// Keys swiped for deletion, held until the user confirms — deleting a key can
    /// lock you out of every server that only trusts it, so never delete on swipe alone.
    @State private var pendingDelete: [SSHPublicKey] = []

    private struct InstallTarget: Identifiable { let id = UUID(); let key: SSHPublicKey }

    var body: some View {
        List {
            Section("Keys in the agent") {
                if store.identities.isEmpty {
                    Text("No keys yet — generate one below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.identities, id: \.blob) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(key.algorithm.rawValue).font(.headline)
                            if store.isHardware(key) {
                                let isFido = store.isSecurityKey(key)
                                let isYubi = store.isYubiKey(key)
                                Tag(text: isFido ? "FIDO2" : (isYubi ? "Smart card" : "Secure Enclave"),
                                    color: Brand.accent,
                                    icon: (isFido || isYubi) ? "key.radiowaves.forward.fill" : "lock.shield.fill")
                            } else {
                                // Software keys live in the Keychain and can be exported.
                                Tag(text: "Software · exportable", color: .orange, icon: "externaldrive")
                            }
                        }
                        Text(SSHKeyFormat.fingerprint(ofPublicKeyBlob: key.blob))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(authorizedKeysLine(key))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        HStack(spacing: 16) {
                            Button {
                                UIPasteboard.general.string = authorizedKeysLine(key)
                                copied = key.blob.base64EncodedString()
                            } label: {
                                Label(copied == key.blob.base64EncodedString() ? "Copied!" : "Copy public key",
                                      systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            ShareLink(item: authorizedKeysLine(key)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderless)
                            Button {
                                installTarget = InstallTarget(key: key)
                            } label: {
                                Label("Install on a host…", systemImage: "key.horizontal")
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.caption)
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    pendingDelete = offsets.map { store.identities[$0] }
                }
            }

            Section {
                if store.enclaveAvailable {
                    Button {
                        Task {
                            do {
                                try await store.generateEnclaveKey()
                                showEnclaveBackupWarning = true
                            }
                            catch { genError = "Couldn't create the key: \(error.localizedDescription)" }
                        }
                    } label: {
                        Label("Secure Enclave key (Face ID)", systemImage: "lock.shield.fill")
                    }
                }
                if let genError {
                    Text(genError).font(.caption).foregroundStyle(.red)
                }
                Button {
                    fidoName = "bsns"
                    fidoPin = ""
                    showFidoEnroll = true
                } label: {
                    Label("FIDO2 security key (USB-C / NFC)", systemImage: "lock.badge.clock")
                }
                Button("Ed25519 (software key)") {
                    Task { await store.generateKey(.ed25519) }
                }
                Button("ECDSA P-256 (software key)") {
                    Task { await store.generateKey(.ecdsaP256) }
                }
                DisclosureGroup("Advanced") {
                    Button {
                        showYubiKey = true
                    } label: {
                        Label("Smart card (PIV)", systemImage: "key.radiowaves.forward.fill")
                    }
                    Button("RSA 3072 (software key)") {
                        Task { await store.generateKey(.rsa) }
                    }
                }
            } header: {
                Text("Generate")
            } footer: {
                let enclaveNote = store.enclaveAvailable
                    ? "A Secure Enclave key never leaves this device and asks for Face ID each time it signs — but it can't be backed up, so if you lose this device you're locked out of any server that only trusts it. Enroll a second key on another device as a backup.\n\n"
                    : ""
                Text(enclaveNote
                    + "Software keys back up + sync across your devices (Settings → Backup) — a good everyday key. Portable FIDO2 resident keys can use one authorized_keys line across supported phones with the same physical key. Secure Enclave is strongest for this device only.\n\nAdvanced — a smart card (PIV) makes a plain ECDSA key every server accepts. Use RSA only for older gear that can't accept Ed25519 or ECDSA.")
            }

            Section {
                Text("Add a key to a server with **ssh-copy-id** on the Connect tab, or copy the line above into the server's `~/.ssh/authorized_keys`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Keys")
        .task { await store.refresh() }
        .alert(pendingDelete.count > 1 ? "Delete \(pendingDelete.count) keys?" : "Delete this key?",
               isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            Button("Delete", role: .destructive) {
                let targets = pendingDelete
                pendingDelete = []
                Task { for identity in targets { await store.deleteKey(identity) } }
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("This removes the key from the agent and this device. Any server that only trusts this key will lock you out — and a software key that isn't backed up can't be recovered.")
        }
        .alert("Add a backup key", isPresented: $showEnclaveBackupWarning) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("""
            This Secure Enclave key is locked to this device and can't be backed up or copied off it. If the device is lost or broken, you'll be locked out of every server that only trusts this key.

            Enroll a second hardware-backed key on another device (or a YubiKey), and make sure BOTH public keys are added to each server's authorized_keys.
            """)
        }
        .sheet(item: $installTarget) { target in
            InstallKeyView(keyLines: [authorizedKeysLine(target.key)],
                           keyLabel: "\(target.key.algorithm.rawValue)  ·  \(SSHKeyFormat.fingerprint(ofPublicKeyBlob: target.key.blob))")
        }
        .sheet(isPresented: $showYubiKey) { YubiKeyEnrollView() }
        .sheet(isPresented: $showFidoEnroll, onDismiss: { fidoPin = "" }) {
            FidoSecurityKeySheet(
                name: $fidoName,
                pin: $fidoPin,
                create: { label, pin in
                    try await store.enrollSecurityKey(name: label, pin: pin)
                },
                createApple: { label in
                    try await store.enrollAppleSecurityKey(name: label)
                },
                importExisting: { pin in
                    try await store.importSecurityKeys(pin: pin)
                }
            )
        }
    }
}

private struct FidoSecurityKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var name: String
    @Binding var pin: String
    let create: (String, String) async throws -> Void
    let createApple: (String) async throws -> Void
    let importExisting: (String) async throws -> Int

    @State private var busy = false
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Security-key PIN", text: $pin)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("Use the PIN for portable OpenSSH resident keys. The private key never leaves the security key.")
                }

                Section {
                    Button("Create portable key") { runCreate() }
                        .disabled(busy || cleanedPIN.isEmpty)
                    Button("Import portable key") { runImport() }
                        .disabled(busy || cleanedPIN.isEmpty)
                } footer: {
                    Text("Portable keys use the OpenSSH application string shared with Android. On iPhone, remove USB-C security keys and tap with NFC if native FIDO2 is not exposed over USB-C.")
                }

                Section {
                    Button("Create with iOS prompt") { runCreateApple() }
                        .disabled(busy)
                } footer: {
                    Text("Uses Apple's USB-C/NFC security-key prompt and asks for the PIN itself. This creates a separate WebAuthn-backed authorized_keys line and cannot import an existing portable key.")
                }

                if busy {
                    Section {
                        HStack { ProgressView(); Text("Waiting for security key…") }
                            .foregroundStyle(.secondary)
                    }
                }
                if let message {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(messageIsError ? .red : Brand.accent)
                    }
                }
            }
            .navigationTitle("Add FIDO2 key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pin = ""; dismiss() }
                        .disabled(busy)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var cleanedPIN: String {
        pin.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runCreate() {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pin = cleanedPIN
        guard !pin.isEmpty else {
            show("Enter the security-key PIN first.", error: true)
            return
        }
        busy = true
        message = nil
        Task {
            do {
                try await create(label, pin)
                self.pin = ""
                dismiss()
            } catch {
                show("Couldn't create the security-key credential: \(error.localizedDescription)", error: true)
            }
            busy = false
        }
    }

    private func runImport() {
        let pin = cleanedPIN
        guard !pin.isEmpty else {
            show("Enter the security-key PIN first.", error: true)
            return
        }
        busy = true
        message = nil
        Task {
            do {
                let imported = try await importExisting(pin)
                self.pin = ""
                if imported == 0 {
                    show("That security-key credential is already added.", error: false)
                } else {
                    dismiss()
                }
            } catch {
                show("Couldn't import the security key: \(error.localizedDescription)", error: true)
            }
            busy = false
        }
    }

    private func runCreateApple() {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        message = nil
        Task {
            do {
                try await createApple(label)
                self.pin = ""
                dismiss()
            } catch {
                show("Couldn't create the iOS security-key credential: \(error.localizedDescription)", error: true)
            }
            busy = false
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}
