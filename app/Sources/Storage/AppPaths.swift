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
}
