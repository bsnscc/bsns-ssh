import Foundation
import Security

/// Where the app keeps its own files.
///
/// On iOS the system directories already sit inside the app's container. A Mac
/// app that isn't sandboxed gets the user's shared `~/Library/Application
/// Support` and `~/Library/Caches`, so there it works in a folder of its own
/// rather than dropping `hosts.json` among everyone else's.
enum AppPaths {
    static let support: URL = directory(.applicationSupportDirectory)
    static let caches: URL = directory(.cachesDirectory)

    private static func directory(_ kind: FileManager.SearchPathDirectory) -> URL {
        var dir = FileManager.default.urls(for: kind, in: .userDomainMask)[0]
        #if os(macOS)
        dir.appendPathComponent(Bundle.main.bundleIdentifier ?? "cc.bsns.ssh", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Every keychain query the app makes goes through here. On the Mac this
/// selects the data-protection keychain: items there belong to the app's
/// identifier and team, so they are never behind the login keychain's
/// per-item permission dialogs, and they survive the app being rebuilt or
/// updated. iOS has only that keychain.
///
/// Earlier Mac builds kept their items in the login keychain, which is a
/// separate store. At launch, before the saved keys are loaded, anything still
/// there is moved across (`migrateIfNeeded`), so an upgrade doesn't make saved
/// keys, the sync passphrase or the pairing identity vanish.
enum Keychain {
    static func scoped(_ query: [String: Any]) -> [String: Any] {
        #if os(macOS)
        var query = query
        query[kSecUseDataProtectionKeychain as String] = true
        return query
        #else
        return query
        #endif
    }

    #if os(macOS)
    /// The services this app has ever stored under.
    static let services = ["cc.bsns.ssh.keys", "cc.bsns.ssh.sync", "cc.bsns.ssh.link"]

    private static let once = NSLock()
    nonisolated(unsafe) private static var migration: Task<Void, Never>?

    /// Move login-keychain items across, once per launch, and wait for it.
    /// Off the main thread: reading an old item can stop to ask the user, and
    /// the app's window shouldn't wait on that.
    static func migrateIfNeeded() async {
        let task: Task<Void, Never> = once.withLock {
            if let migration { return migration }
            let started = Task.detached(priority: .userInitiated) { _ = migrateFromLoginKeychain() }
            migration = started
            return started
        }
        await task.value
    }

    /// Move every item of ours from the login keychain to the data-protection
    /// keychain. Listing them reads attributes only, which never prompts, so a
    /// Mac with nothing to move pays nothing. An item is deleted from the old
    /// store only once it is safely in the new one; one that can't be read
    /// (the user declined the prompt) stays put and is tried again next launch.
    @discardableResult
    static func migrateFromLoginKeychain() -> Int {
        var moved = 0
        for service in services {
            // Every query against the old store says so explicitly. Left
            // unsaid, a query reaches both stores — and this would then "move"
            // items that are already in the new one, and delete them.
            let listing: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecUseDataProtectionKeychain as String: false,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
            ]
            var found: AnyObject?
            guard SecItemCopyMatching(listing as CFDictionary, &found) == errSecSuccess,
                  let items = found as? [[String: Any]] else { continue }
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String else { continue }
                let legacy: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecUseDataProtectionKeychain as String: false,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                ]
                var read = legacy
                read[kSecReturnData as String] = true
                read[kSecMatchLimit as String] = kSecMatchLimitOne
                var value: AnyObject?
                guard SecItemCopyMatching(read as CFDictionary, &value) == errSecSuccess,
                      let data = value as? Data else { continue }
                var add = legacy
                add[kSecUseDataProtectionKeychain as String] = true
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let status = SecItemAdd(add as CFDictionary, nil)
                // Already there means a newer copy exists; the old one is stale.
                guard status == errSecSuccess || status == errSecDuplicateItem else { continue }
                SecItemDelete(legacy as CFDictionary)
                if status == errSecSuccess { moved += 1 }
            }
        }
        return moved
    }
    #endif
}
