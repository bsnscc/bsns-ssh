import Foundation

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
