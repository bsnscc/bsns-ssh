import Foundation
import Security
import BsnsSSHCore

/// Persists FileKey material in the iOS Keychain — hardware-protected at rest,
/// device-bound, available after first unlock. (Secure Enclave / hardware-token
/// keys never pass through here; they're non-extractable by construction.)
enum KeyStore {
    private static let service = "cc.bsns.ssh.keys"

    private struct Stored: Codable {
        let algorithm: String
        let material: Data        // software: raw private key; enclave: wrapped key data; yubikey: public blob
        let comment: String
        var kind: String?          // nil/"file" = software; "enclave" = Secure Enclave; "yubikey" = PIV token
        var slot: UInt8?           // yubikey: PIV slot
    }

    static func save(_ key: FileKey) {
        persist(account: key.id.rawValue, Stored(
            algorithm: key.algorithm.rawValue,
            material: key.exportPrivateKeyMaterial(),
            comment: key.publicKey.comment, kind: "file"))
    }

    static func saveEnclave(_ key: SecureEnclaveKey) {
        persist(account: key.id.rawValue, Stored(
            algorithm: key.algorithm.rawValue,
            material: key.keyData,
            comment: key.publicKey.comment, kind: "enclave"))
    }

    static func saveYubiKey(_ key: YubiKeyPIVKey) {
        persist(account: key.id.rawValue, Stored(
            algorithm: key.algorithm.rawValue,
            material: key.publicKey.blob,
            comment: key.publicKey.comment, kind: "yubikey", slot: key.slot))
    }

    private static func persist(account: String, _ stored: Stored) {
        guard let payload = try? JSONEncoder().encode(stored) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = payload
        // WhenUnlocked (not AfterFirstUnlock): key material is only readable while
        // the device is unlocked, never device-locked or from a background launch.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
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
