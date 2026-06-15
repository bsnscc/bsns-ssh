import Foundation
import Observation
import Security

enum SyncError: Error, LocalizedError {
    case notConfigured, noFile, staleBookmark

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Pick a sync folder first."
        case .noFile: return "No sync file there yet — push from another device first."
        case .staleBookmark: return "Lost access to the sync folder — pick it again."
        }
    }
}

/// Cross-device sync over storage the user controls. The synced payload is the
/// same client-encrypted config bundle the Backup screen produces, so whatever
/// the storage is (iCloud Drive / Google Drive / Dropbox — any Files provider
/// the user picks) only ever sees ciphertext. No account, no vendor server.
///
/// We remember the chosen folder with a security-scoped bookmark and keep the
/// passphrase in the Keychain (this device only), so push/pull is one tap and
/// the passphrase never leaves the device.
@MainActor
@Observable
final class SyncStore {
    static let fileName = "bsns-ssh-sync.json"
    private let bookmarkKey = "sync.folderBookmark"
    private let service = "cc.bsns.ssh.sync"

    private(set) var folderName: String?     // display only
    var lastStatus: String?

    init() {
        if let url = resolvedFolder() { folderName = url.lastPathComponent }
    }

    var isConfigured: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }
    var hasPassphrase: Bool { loadPassphrase() != nil }

    // MARK: folder

    /// Persist access to a folder the user picked via the document picker.
    func setFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            folderName = url.lastPathComponent
        }
    }

    private func resolvedFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if stale {
            // Refresh the stored bookmark from the resolved URL so access doesn't
            // lapse; if we can't, drop it so the user is asked to pick again.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            } else {
                UserDefaults.standard.removeObject(forKey: bookmarkKey)
                return nil
            }
        }
        return url
    }

    // MARK: push / pull

    func push(_ bundle: Data) throws {
        guard let folder = resolvedFolder() else { throw SyncError.notConfigured }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let file = folder.appendingPathComponent(Self.fileName)
        var coordErr: NSError?
        var writeErr: Error?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordErr) { url in
            do { try bundle.write(to: url, options: .atomic) } catch { writeErr = error }
        }
        if let e = writeErr ?? coordErr { throw e }
    }

    func pull() throws -> Data {
        guard let folder = resolvedFolder() else { throw SyncError.notConfigured }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let file = folder.appendingPathComponent(Self.fileName)
        // Pull the file down if it lives in the cloud and isn't materialized yet.
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        var coordErr: NSError?
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordErr) { url in
            data = try? Data(contentsOf: url)
        }
        if let coordErr { throw coordErr }
        guard let data else { throw SyncError.noFile }
        return data
    }

    // MARK: passphrase (Keychain, this device only)

    func savePassphrase(_ passphrase: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "passphrase",
        ]
        SecItemDelete(query as CFDictionary)
        guard !passphrase.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(passphrase.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    func loadPassphrase() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "passphrase",
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
