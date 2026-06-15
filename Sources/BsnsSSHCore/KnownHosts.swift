import Foundation

/// A server's host key as presented during the handshake.
public struct HostKey: Sendable, Equatable, Codable {
    /// SSH key-type name, e.g. "ssh-ed25519" / "ecdsa-sha2-nistp256".
    public let keyType: String
    /// Raw host-key blob (as returned by the transport).
    public let blob: Data

    public init(keyType: String, blob: Data) {
        self.keyType = keyType
        self.blob = blob
    }

    public var fingerprint: String { SSHKeyFormat.fingerprint(ofPublicKeyBlob: blob) }
}

/// The result of checking a presented host key against what we've stored.
public enum HostVerification: Sendable, Equatable {
    /// Key matches a stored entry — proceed.
    case trusted
    /// No stored entry — first contact (TOFU). Prompt the user with the
    /// fingerprint; on accept, call `trust(...)`.
    case unknown(fingerprint: String)
    /// A different key than the one stored — the dangerous case. Do NOT
    /// proceed without an explicit, loud user override.
    case mismatch(stored: String, presented: String)
}

/// Trust-on-first-use host-key store. Pure + serializable; the prompt UI and
/// persistence (sync blob / disk) live above it.
public struct KnownHosts: Sendable, Equatable, Codable {
    private var entries: [String: HostKey]

    public init(entries: [String: HostKey] = [:]) {
        self.entries = entries
    }

    /// Check a presented key. Never mutates — accepting a TOFU prompt is an
    /// explicit `trust(...)` call by the caller.
    public func verify(host: String, port: UInt16, key: HostKey) -> HostVerification {
        guard let stored = entries[Self.identifier(host, port)] else {
            return .unknown(fingerprint: key.fingerprint)
        }
        if stored.blob == key.blob { return .trusted }
        return .mismatch(stored: stored.fingerprint, presented: key.fingerprint)
    }

    /// Record a key as trusted for a host (after a TOFU accept, or an explicit
    /// override on mismatch).
    public mutating func trust(host: String, port: UInt16, key: HostKey) {
        entries[Self.identifier(host, port)] = key
    }

    public func storedKey(host: String, port: UInt16) -> HostKey? {
        entries[Self.identifier(host, port)]
    }

    public var allEntries: [String: HostKey] { entries }

    /// Forget a trusted host by its identifier (a key from `allEntries`).
    public mutating func forget(_ identifier: String) {
        entries[identifier] = nil
    }

    /// OpenSSH-style host identifier: bare host on port 22, else `[host]:port`.
    static func identifier(_ host: String, _ port: UInt16) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }
}
