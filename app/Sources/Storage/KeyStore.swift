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
        let material: Data
        let comment: String
    }

    static func save(_ key: FileKey) {
        guard let payload = try? JSONEncoder().encode(Stored(
            algorithm: key.algorithm.rawValue,
            material: key.exportPrivateKeyMaterial(),
            comment: key.publicKey.comment))
        else { return }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.id.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = payload
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadAll() -> [FileKey] {
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

        return items.compactMap { item in
            guard let data = item[kSecValueData as String] as? Data,
                  let stored = try? JSONDecoder().decode(Stored.self, from: data),
                  let algorithm = KeyAlgorithm(rawValue: stored.algorithm)
            else { return nil }
            return try? FileKey.from(algorithm: algorithm, privateKeyMaterial: stored.material, comment: stored.comment)
        }
    }

    static func delete(_ id: KeyID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
