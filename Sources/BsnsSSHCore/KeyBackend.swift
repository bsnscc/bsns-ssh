import Foundation

/// Stable identifier for a key within the agent.
public struct KeyID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// SSH public-key / signature algorithm name — the string that appears on the
/// wire and in `authorized_keys`.
public enum KeyAlgorithm: String, Sendable, CaseIterable {
    case ed25519 = "ssh-ed25519"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
    // RSA — the compatibility path for legacy gear (older networking equipment,
    // appliances) that predates Ed25519/ECDSA support. "ssh-rsa" is the key-blob
    // type; the signature hash is negotiated separately (see RSASignatureAlgorithm).
    case rsa = "ssh-rsa"
    // FIDO2 security-key types. New mobile credentials use native CTAP2/OpenSSH
    // signatures on both iOS and Android; iOS still loads legacy WebAuthn-created
    // credentials whose assertions use the webauthn-sk signature variant.
    case ecdsaSK = "sk-ecdsa-sha2-nistp256@openssh.com"
    case ed25519SK = "sk-ssh-ed25519@openssh.com"

    /// True for FIDO2 security-key types (assertion carries a presence flag +
    /// signature counter).
    public var isSecurityKey: Bool {
        switch self {
        case .ecdsaSK, .ed25519SK: return true
        case .ed25519, .ecdsaP256, .rsa: return false
        }
    }
}

/// The signature hash to use for an `ssh-rsa` key. The public-key blob is always
/// "ssh-rsa", but RFC 8332 lets the signature use SHA-256/512; legacy gear that
/// can't do ECDSA usually also expects the original SHA-1 ("ssh-rsa") signature,
/// which is why that is the default. The raw value is the on-the-wire signature
/// algorithm name.
public enum RSASignatureAlgorithm: String, Sendable {
    case sha1 = "ssh-rsa"
    case sha256 = "rsa-sha2-256"
    case sha512 = "rsa-sha2-512"
}

/// A public key in SSH wire format plus its human comment. `blob` is exactly
/// what would appear (base64-encoded) in an `authorized_keys` line.
public struct SSHPublicKey: Sendable, Equatable {
    public let blob: Data
    public let algorithm: KeyAlgorithm
    public let comment: String

    public init(blob: Data, algorithm: KeyAlgorithm, comment: String = "") {
        self.blob = blob
        self.algorithm = algorithm
        self.comment = comment
    }
}

/// A complete SSH signature blob: `string(algorithm) || string(signature-body)`.
/// This is what the transport's sign callback ultimately needs. For the ECDSA
/// path the signature-body is `mpint(r) || mpint(s)`.
public struct SSHSignature: Sendable, Equatable {
    public let blob: Data
    public init(blob: Data) { self.blob = blob }
}

/// Why a signature is being requested and for whom — surfaced on the biometric
/// prompt, and (v1.5) shown on the phone before a remote machine's request is
/// approved. The agent never signs without a context.
public struct SignContext: Sendable {
    public enum Purpose: Sendable {
        case sshUserAuth   // authenticating an SSH session
        case detachedSign  // the standalone hash/sign tool
        case remoteAgent   // v1.5: a request forwarded from another machine
    }

    public let host: String?
    public let purpose: Purpose
    /// Which signature hash an `ssh-rsa` key should use. Defaults to SHA-1, which
    /// matches the "ssh-rsa" method libssh2 advertises for an ssh-rsa blob on the
    /// userauth callback path (and what legacy gear expects). The agent-protocol
    /// path overrides this from the request's rsa-sha2 flags.
    public let rsaAlgorithm: RSASignatureAlgorithm
    /// The program that asked, when the request came from outside the app (the
    /// agent socket) — "ssh", "git". Shown on the approval prompt and recorded
    /// in the audit trail, so a signature is never requested anonymously.
    public let requester: String?
    /// The account being logged in to, when the request reveals it.
    public let user: String?
    /// Whether `host` is established rather than merely claimed. The app's own
    /// connections have checked the server's host key before they ask; a
    /// request from outside proves its destination only when the data to be
    /// signed itself names the server's key. A key limited to certain hosts
    /// signs only for a proven one.
    public let hostProven: Bool

    public init(host: String? = nil, purpose: Purpose, rsaAlgorithm: RSASignatureAlgorithm = .sha1,
                requester: String? = nil, user: String? = nil, hostProven: Bool = true) {
        self.host = host
        self.purpose = purpose
        self.rsaAlgorithm = rsaAlgorithm
        self.requester = requester
        self.user = user
        self.hostProven = hostProven
    }

    /// One line for an approval prompt: who is asking, and for what.
    public var promptReason: String {
        let target = host.map { h in user.map { "\($0)@\(h)" } ?? h }
        switch (requester, target) {
        case let (requester?, target?): return "\(requester) wants to sign in to \(target)"
        case let (requester?, nil): return "\(requester) wants to use this key"
        case let (nil, target?): return "Sign in to \(target)"
        case (nil, nil): return "Authorize SSH sign-in"
        }
    }
}

public enum KeyBackendError: Error, Sendable {
    case userCancelled
    case userPresenceRequired
    /// The key is limited to certain hosts and this request isn't for one.
    case notPermitted
    case unsupportedAlgorithm
    case signingFailed(String)
}

/// The uniform interface every key implementation satisfies. The agent talks
/// only to this — it does not care whether a key lives in the Secure Enclave,
/// an encrypted file, or on a hardware token. That single fact is what makes
/// on-device SSH, hardware tokens, and the phone-as-hardware-key feature the
/// same code path with different callers.
///
/// Concrete backends (separate files, added per the build order):
///   - `SecureEnclaveKey`  non-extractable, biometric-gated, ECDSA P-256
///   - `FileKey`           encrypted at rest, exportable, syncable
///   - `YubiKeyPIVKey`     smartcard ECDSA over NFC / USB-C / Lightning (v1)
public protocol KeyBackend: Sendable {
    var id: KeyID { get }
    var publicKey: SSHPublicKey { get }
    var algorithm: KeyAlgorithm { get }

    /// False for Enclave / hardware-token keys (non-extractable by
    /// construction); true for file keys.
    var canExport: Bool { get }

    /// Whether signing requires a user-presence gate (biometric / token touch).
    var requiresUserPresence: Bool { get }

    /// Sign `data` and return a complete SSH signature blob. Implementations
    /// MUST NOT expose private-key material; non-extractable backends sign in
    /// hardware.
    func sign(_ data: Data, context: SignContext) async throws -> SSHSignature
}
