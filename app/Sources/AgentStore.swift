import Foundation
import Observation
import BsnsSSHCore

/// App-level holder for the agent and its visible identities. The agent is the
/// heart — every key the UI shows or uses lives here. Keys are persisted in the
/// Keychain and reloaded into the agent on launch.
@MainActor
@Observable
final class AgentStore {
    let agent = Agent()
    private(set) var identities: [SSHPublicKey] = []
    /// Fingerprints of hardware-backed keys, and the subset that are YubiKeys.
    private(set) var hardwareKeyIDs: Set<String> = []
    private(set) var yubiKeyIDs: Set<String> = []
    private(set) var securityKeyIDs: Set<String> = []

    /// Whether this device can create Secure Enclave keys (false on the simulator).
    var enclaveAvailable: Bool { SecureEnclaveKey.isAvailable }

    init() {
        Task {
            for key in KeyStore.loadAll() {
                await agent.add(key)
                if key.requiresUserPresence { hardwareKeyIDs.insert(key.id.rawValue) }
                if key is YubiKeyPIVKey { yubiKeyIDs.insert(key.id.rawValue) }
                if key is WebAuthnSecurityKey || key is Fido2SecurityKey { securityKeyIDs.insert(key.id.rawValue) }
            }
            await refresh()
        }
    }

    /// Enroll a YubiKey: read its PIV public key and add it as an identity.
    func enrollYubiKey(pin: String, managementKeyHex: String? = nil) async throws {
        let blob = try await YubiKeyCoordinator.shared.enroll(pin: pin, managementKeyHex: managementKeyHex)
        let key = YubiKeyPIVKey.make(publicBlob: blob, slot: YubiKeyCoordinator.slot, comment: "YubiKey")
        try KeyStore.saveYubiKey(key)
        await agent.add(key)
        hardwareKeyIDs.insert(key.id.rawValue)
        yubiKeyIDs.insert(key.id.rawValue)
        await refresh()
    }

    func isYubiKey(_ identity: SSHPublicKey) -> Bool {
        yubiKeyIDs.contains(SSHKeyFormat.fingerprint(ofPublicKeyBlob: identity.blob))
    }

    func isSecurityKey(_ identity: SSHPublicKey) -> Bool {
        securityKeyIDs.contains(SSHKeyFormat.fingerprint(ofPublicKeyBlob: identity.blob))
    }

    /// Enroll a portable OpenSSH FIDO2 resident credential. The private key stays
    /// on the token; iOS stores only the public blob + credential id needed to ask
    /// that token for assertions later.
    func enrollSecurityKey(name: String, pin: String) async throws {
        let result = try await Fido2Coordinator.shared.enroll(pin: pin, name: name)
        let key = Fido2SecurityKey.make(publicBlob: result.publicBlob,
                                        credentialID: result.credentialID,
                                        application: result.application,
                                        comment: name.isEmpty ? "FIDO2 security key" : name)
        try KeyStore.saveFido2(key)
        await agent.add(key)
        hardwareKeyIDs.insert(key.id.rawValue)
        securityKeyIDs.insert(key.id.rawValue)
        await refresh()
    }

    /// Enroll a security-key credential through Apple's WebAuthn prompt. This
    /// works with iOS-managed USB-C/NFC security-key transports, but the
    /// resulting authorized_keys line is tied to the WebAuthn relying-party
    /// domain rather than the portable OpenSSH `ssh:bsns` application string.
    func enrollAppleSecurityKey(name: String) async throws {
        let result = try await WebAuthnCoordinator.shared.enroll(name: name)
        let key = WebAuthnSecurityKey.make(publicBlob: result.publicBlob,
                                           credentialID: result.credentialID,
                                           comment: name.isEmpty ? "iOS security key" : name)
        try KeyStore.saveWebAuthn(key)
        await agent.add(key)
        hardwareKeyIDs.insert(key.id.rawValue)
        securityKeyIDs.insert(key.id.rawValue)
        await refresh()
    }

    /// Import existing portable bsns.SSH resident credentials from a token. This
    /// is the cross-phone path: Android can create the credential, iOS can import
    /// it, and both advertise the same authorized_keys line.
    @discardableResult
    func importSecurityKeys(pin: String) async throws -> Int {
        let results = try await Fido2Coordinator.shared.importResident(pin: pin)
        var existing = Set(identities.map { SSHKeyFormat.fingerprint(ofPublicKeyBlob: $0.blob) })
        var imported = 0
        for result in results {
            let fingerprint = SSHKeyFormat.fingerprint(ofPublicKeyBlob: result.publicBlob)
            guard !existing.contains(fingerprint) else { continue }
            let key = Fido2SecurityKey.make(publicBlob: result.publicBlob,
                                            credentialID: result.credentialID,
                                            application: result.application,
                                            comment: "FIDO2 security key")
            try KeyStore.saveFido2(key)
            await agent.add(key)
            hardwareKeyIDs.insert(key.id.rawValue)
            securityKeyIDs.insert(key.id.rawValue)
            existing.insert(fingerprint)
            imported += 1
        }
        await refresh()
        return imported
    }

    func refresh() async {
        identities = await agent.identities()
    }

    func generateKey(_ algorithm: KeyAlgorithm) async {
        guard let key = try? FileKey.generate(algorithm: algorithm, comment: "generated on device") else {
            return
        }
        // Persist before adopting it in-memory: if the Keychain write fails, don't
        // hand the agent a key that won't survive relaunch (it would silently vanish).
        do { try KeyStore.save(key) }
        catch { DiagLog.log("keystore", "generate save failed: \(error.localizedDescription)"); return }
        await agent.add(key)
        await refresh()
    }

    /// Create a non-extractable P-256 key in the Secure Enclave (Face ID per use).
    func generateEnclaveKey() async throws {
        let key = try SecureEnclaveKey.generate(comment: "Secure Enclave key")
        try KeyStore.saveEnclave(key)
        await agent.add(key)
        hardwareKeyIDs.insert(key.id.rawValue)
        await refresh()
    }

    func isHardware(_ identity: SSHPublicKey) -> Bool {
        hardwareKeyIDs.contains(SSHKeyFormat.fingerprint(ofPublicKeyBlob: identity.blob))
    }

    /// Software keys currently held (for export).
    func exportableKeys() -> [FileKey] { KeyStore.loadFileKeys() }

    /// Import a software key from a config bundle, skipping duplicates.
    func importKey(_ key: FileKey) async {
        let existing = Set(identities.map { SSHKeyFormat.fingerprint(ofPublicKeyBlob: $0.blob) })
        guard !existing.contains(SSHKeyFormat.fingerprint(ofPublicKeyBlob: key.publicKey.blob)) else { return }
        // Persist before adopting it in-memory (see generateKey): a failed write
        // must not leave a phantom key the agent uses but the Keychain doesn't hold.
        do { try KeyStore.save(key) }
        catch { DiagLog.log("keystore", "import save failed: \(error.localizedDescription)"); return }
        await agent.add(key)
        await refresh()
    }

    func deleteKey(_ identity: SSHPublicKey) async {
        let id = KeyID(SSHKeyFormat.fingerprint(ofPublicKeyBlob: identity.blob))
        KeyStore.delete(id)
        await agent.remove(id)
        hardwareKeyIDs.remove(id.rawValue)
        yubiKeyIDs.remove(id.rawValue)
        securityKeyIDs.remove(id.rawValue)
        await refresh()
    }
}
