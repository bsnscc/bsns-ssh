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
                    let targets = offsets.map { store.identities[$0] }
                    Task { for identity in targets { await store.deleteKey(identity) } }
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
                    + "Software keys back up + sync across your devices (Settings → Backup) — a good everyday key. FIDO2 and Secure Enclave are stronger hardware keys.\n\nAdvanced — a smart card (PIV) makes a plain ECDSA key every server accepts, and the same physical card works on iOS and Android with one authorized_keys line. Use RSA only for older gear that can't accept Ed25519 or ECDSA.")
            }

            Section {
                Text("Add a key to a server with **ssh-copy-id** on the Connect tab, or copy the line above into the server's `~/.ssh/authorized_keys`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Keys")
        .task { await store.refresh() }
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
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                Task {
                    do { try await store.enrollSecurityKey(name: fidoName) }
                    catch { genError = "Couldn't enroll the security key: \(error.localizedDescription)" }
                }
            }
        } message: {
            Text("""
            Touch your security key (and enter its PIN if asked) on the next screen. The private key never leaves it.

            The same physical key works on iOS and Android, but each platform needs its own enrollment — add both public keys to your server. As with any single hardware key, also keep a backup key so a lost one doesn't lock you out. (For one key that works on both platforms with a single line, use a smart card (PIV) under Advanced.)
            """)
        }
    }
}
