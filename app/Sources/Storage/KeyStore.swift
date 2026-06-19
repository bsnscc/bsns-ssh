import Foundation
import Security
import BsnsSSHCore

/// Persists FileKey material in the iOS Keychain — hardware-protected at rest,
/// device-bound, available after first unlock. (Secure Enclave / hardware-token
/// keys never pass through here; they're non-extractable by construction.)
enum KeyStore {
    private static let service = "cc.bsns.ssh.keys"

    enum StoreError: Error, LocalizedError {
        case encodeFailed
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .encodeFailed: return "Couldn't encode the key for storage."
            case .keychain(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Couldn't save the key to the Keychain: \(detail)."
            }
        }
    }

    private struct Stored: Codable {
        let algorithm: String
        let material: Data        // software: raw private key; enclave: wrapped key data; yubikey: public blob
        let comment: String
        var kind: String?          // nil/"file" = software; "enclave" = Secure Enclave; "yubikey" = PIV token; "webauthn" = FIDO2 security key
        var slot: UInt8?           // yubikey: PIV slot
        var credentialID: Data?    // webauthn: FIDO credential id (material holds the public blob)
    }

    static func save(_ key: FileKey) throws {
        try persist(account: key.id.rawValue, Stored(
            algorithm: key.algorithm.rawValue,
            material: key.exportPrivateKeyMaterial(),
            comment: key.publicKey.comment, kind: "file"))
    }

    static func saveEnclave(_ key: SecureEnclaveKey) throws {
        try persist(account: key.id.rawValue, Stored(
            algorithm: key.algorithm.rawValue,
            material: key.keyData,
            comment: key.publicKey.comment, kind: "enclave"))
    }

    static func saveYubiKey(_ key: YubiKeyPIVKey) throws {
        try persist(account: key.id.rawValue, Stored(
            algorithm: key.algorithm.rawValue,
            material: key.publicKey.blob,
            comment: key.publicKey.comment, kind: "yubikey", slot: key.slot))
    }

    static func saveWebAuthn(_ key: WebAuthnSecurityKey) throws {
        try persist(account: key.id.rawValue, Stored(
            algorithm: key.algorithm.rawValue,
            material: key.publicKey.blob,
            comment: key.publicKey.comment, kind: "webauthn", credentialID: key.credentialID))
    }

    /// Persist a record without ever destroying the existing one before the new
    /// write lands: UPDATE in place, and only ADD if there's nothing there yet.
    /// A failed encode or any non-success OSStatus throws, so a caller can never
    /// believe a save succeeded when the Keychain still holds the old (or no) value.
    private static func persist(account: String, _ stored: Stored) throws {
        guard let payload = try? JSONEncoder().encode(stored) else { throw StoreError.encodeFailed }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // WhenUnlocked (not AfterFirstUnlock): key material is only readable while
        // the device is unlocked, never device-locked or from a background launch.
        let attrs: [String: Any] = [
            kSecValueData as String: payload,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw StoreError.keychain(updateStatus) }
        // Nothing to update — add it. No delete-then-add: a record is never lost.
        let addStatus = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil)
        if addStatus != errSecSuccess { throw StoreError.keychain(addStatus) }
    }

    /// All persisted keys as their backends (software + enclave).
    static func loadAll() -> [any KeyBackend] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { item -> (any KeyBackend)? in
            guard let data = item[kSecValueData as String] as? Data,
                  let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
            if stored.kind == "enclave" {
                return try? SecureEnclaveKey.from(keyData: stored.material, comment: stored.comment)
            }
            if stored.kind == "yubikey" {
                return YubiKeyPIVKey.make(publicBlob: stored.material, slot: stored.slot ?? 0x9a, comment: stored.comment)
            }
            if stored.kind == "webauthn" {
                return WebAuthnSecurityKey.make(publicBlob: stored.material,
                                                credentialID: stored.credentialID ?? Data(),
                                                comment: stored.comment)
            }
            guard let algorithm = KeyAlgorithm(rawValue: stored.algorithm) else { return nil }
            return try? FileKey.from(algorithm: algorithm, privateKeyMaterial: stored.material, comment: stored.comment)
        }
    }

    /// Only the exportable software keys.
    static func loadFileKeys() -> [FileKey] { loadAll().compactMap { $0 as? FileKey } }

    static func delete(_ id: KeyID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
