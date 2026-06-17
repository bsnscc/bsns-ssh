import Foundation
import CryptoKit

/// A software key: private material held in memory, exportable, and therefore
/// the backend that can sync (the encrypted-at-rest / sync layer wraps the
/// material this type hands back). Supports Ed25519 and ECDSA P-256.
///
/// `FileKey` is a value type holding only raw bytes, so it is trivially
/// `Sendable`. It never writes its material to disk in the clear — persistence
/// and encryption are the caller's responsibility (Keychain / sync blob).
public struct FileKey: KeyBackend {
    public let id: KeyID
    public let algorithm: KeyAlgorithm
    public let publicKey: SSHPublicKey
    public var canExport: Bool { true }
    public var requiresUserPresence: Bool { false }

    private let privateKeyMaterial: Data

    private init(id: KeyID, algorithm: KeyAlgorithm, publicKey: SSHPublicKey, privateKeyMaterial: Data) {
        self.id = id
        self.algorithm = algorithm
        self.publicKey = publicKey
        self.privateKeyMaterial = privateKeyMaterial
    }

    /// Generate a fresh key. Only Ed25519 / ECDSA P-256 are valid for a file
    /// key — the `sk-` types are hardware-token-only.
    public static func generate(algorithm: KeyAlgorithm, comment: String = "") throws -> FileKey {
        switch algorithm {
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            return make(.ed25519,
                        publicBlob: SSHKeyFormat.ed25519PublicBlob(rawPublicKey: key.publicKey.rawRepresentation),
                        material: key.rawRepresentation,
                        comment: comment)
        case .ecdsaP256:
            let key = P256.Signing.PrivateKey()
            return make(.ecdsaP256,
                        publicBlob: SSHKeyFormat.ecdsaP256PublicBlob(x963Point: key.publicKey.x963Representation),
                        material: key.rawRepresentation,
                        comment: comment)
        case .rsa:
            let (publicBlob, material) = try RSAKeySupport.generate()
            return make(.rsa, publicBlob: publicBlob, material: material, comment: comment)
        case .ecdsaSK, .ed25519SK:
            throw KeyBackendError.unsupportedAlgorithm
        }
    }

    /// Reconstruct from raw private material (e.g. after the sync layer
    /// decrypts it).
    public static func from(algorithm: KeyAlgorithm, privateKeyMaterial: Data, comment: String = "") throws -> FileKey {
        switch algorithm {
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyMaterial)
            return make(.ed25519,
                        publicBlob: SSHKeyFormat.ed25519PublicBlob(rawPublicKey: key.publicKey.rawRepresentation),
                        material: privateKeyMaterial,
                        comment: comment)
        case .ecdsaP256:
            let key = try P256.Signing.PrivateKey(rawRepresentation: privateKeyMaterial)
            return make(.ecdsaP256,
                        publicBlob: SSHKeyFormat.ecdsaP256PublicBlob(x963Point: key.publicKey.x963Representation),
                        material: privateKeyMaterial,
                        comment: comment)
        case .rsa:
            return make(.rsa,
                        publicBlob: try RSAKeySupport.publicBlob(fromMaterial: privateKeyMaterial),
                        material: privateKeyMaterial,
                        comment: comment)
        case .ecdsaSK, .ed25519SK:
            throw KeyBackendError.unsupportedAlgorithm
        }
    }

    /// The raw private material, for the encrypted-at-rest / sync layer to wrap.
    public func exportPrivateKeyMaterial() -> Data { privateKeyMaterial }

    public func sign(_ data: Data, context: SignContext) async throws -> SSHSignature {
        switch algorithm {
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyMaterial)
            let raw = try key.signature(for: data)
            return SSHSignature(blob: SSHKeyFormat.signatureBlob(format: "ssh-ed25519", body: raw))
        case .ecdsaP256:
            let key = try P256.Signing.PrivateKey(rawRepresentation: privateKeyMaterial)
            let signature = try key.signature(for: data)
            let body = SSHKeyFormat.ecdsaSignatureBody(rawRS: signature.rawRepresentation)
            return SSHSignature(blob: SSHKeyFormat.signatureBlob(format: "ecdsa-sha2-nistp256", body: body))
        case .rsa:
            let body = try RSAKeySupport.sign(material: privateKeyMaterial, data: data,
                                              algorithm: context.rsaAlgorithm)
            return SSHSignature(blob: SSHKeyFormat.signatureBlob(format: context.rsaAlgorithm.rawValue, body: body))
        case .ecdsaSK, .ed25519SK:
            throw KeyBackendError.unsupportedAlgorithm
        }
    }

    private static func make(_ algorithm: KeyAlgorithm, publicBlob: Data, material: Data, comment: String) -> FileKey {
        FileKey(
            id: KeyID(SSHKeyFormat.fingerprint(ofPublicKeyBlob: publicBlob)),
            algorithm: algorithm,
            publicKey: SSHPublicKey(blob: publicBlob, algorithm: algorithm, comment: comment),
            privateKeyMaterial: material
        )
    }
}
