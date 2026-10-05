import Foundation

/// A key that may only sign in to certain hosts.
///
/// This is what makes a key that signs without asking tolerable: wrapped like
/// this, it answers only for logins to the hosts listed, and only when that
/// destination is established — the app's own connection (which has already
/// checked the server's host key), or an outside request whose data to be
/// signed names the server's key, so the signature is useless anywhere else.
/// Everything else is refused: other hosts, a destination that is only
/// claimed, and signing that isn't a login at all.
public struct ScopedKey: KeyBackend {
    public let base: any KeyBackend
    /// Lowercased host names, as the app knows the hosts.
    public let allowedHosts: Set<String>

    public init(_ base: any KeyBackend, allowedHosts: some Sequence<String>) {
        self.base = base
        self.allowedHosts = Set(allowedHosts.map { Self.hostName($0) })
    }

    public var id: KeyID { base.id }
    public var publicKey: SSHPublicKey { base.publicKey }
    public var algorithm: KeyAlgorithm { base.algorithm }
    public var canExport: Bool { base.canExport }
    public var requiresUserPresence: Bool { base.requiresUserPresence }

    public func permits(_ context: SignContext) -> Bool {
        guard context.purpose != .detachedSign, context.hostProven, let host = context.host else { return false }
        return allowedHosts.contains(Self.hostName(host))
    }

    public func sign(_ data: Data, context: SignContext) async throws -> SSHSignature {
        guard permits(context) else { throw KeyBackendError.notPermitted }
        return try await base.sign(data, context: context)
    }

    /// A bare, lowercased host from either a plain name or a known-hosts
    /// identifier (`[host]:port`).
    public static func hostName(_ text: String) -> String {
        var name = text.lowercased()
        if name.hasPrefix("["), let close = name.firstIndex(of: "]") {
            name = String(name[name.index(after: name.startIndex)..<close])
        }
        return name
    }
}
