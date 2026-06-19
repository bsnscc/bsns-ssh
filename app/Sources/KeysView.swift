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
        .alert("Add a FIDO2 security key", isPresented: $showFidoEnroll) {
            TextField("Label", text: $fidoName)
            SecureField("FIDO2 PIN", text: $fidoPin)
            Button("Cancel", role: .cancel) { fidoPin = "" }
            Button("Create New") {
                let pin = fidoPin.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pin.isEmpty else {
                    genError = "Enter the security key's FIDO2 PIN first."
                    return
                }
                Task {
                    do {
                        try await store.enrollSecurityKey(name: fidoName, pin: pin)
                        fidoPin = ""
                    }
                    catch { genError = "Couldn't enroll the security key: \(error.localizedDescription)" }
                }
            }
            Button("Use Existing") {
                let pin = fidoPin.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pin.isEmpty else {
                    genError = "Enter the security key's FIDO2 PIN first."
                    return
                }
                Task {
                    do {
                        let imported = try await store.importSecurityKeys(pin: pin)
                        fidoPin = ""
                        if imported == 0 { genError = "That FIDO2 credential is already in the agent." }
                    }
                    catch { genError = "Couldn't import the security key: \(error.localizedDescription)" }
                }
            }
        } message: {
            Text("""
            Create or import a resident OpenSSH FIDO2 credential using application ssh:bsns. The private key never leaves the security key.

            The same resident credential can be used by bsns.SSH on iOS and Android with one authorized_keys line, as long as the phone can talk to the key and the server supports OpenSSH FIDO2 security-key auth. Keep a backup key so a lost one doesn't lock you out.
            """)
        }
    }
}
