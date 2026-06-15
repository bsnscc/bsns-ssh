import Foundation
import CryptoKit
import Security
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// A P-256 signing key generated and held in the Secure Enclave. The private key
/// never exists outside the enclave — `keyData` is an enclave-wrapped reference,
/// useless on any other device. Every signature requires user presence
/// (Face ID / Touch ID / passcode), so the key cannot be used silently.
public struct SecureEnclaveKey: KeyBackend {
    public let id: KeyID
    public let algorithm: KeyAlgorithm = .ecdsaP256
    public let publicKey: SSHPublicKey
    public var canExport: Bool { false }
    public var requiresUserPresence: Bool { true }

    /// Enclave-wrapped key reference — persist this; it is not the private key.
    public let keyData: Data

    /// Whether this device actually has a Secure Enclave (false on the simulator).
    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public static func generate(comment: String = "") throws -> SecureEnclaveKey {
        guard isAvailable else { throw KeyBackendError.signingFailed("no Secure Enclave on this device") }
        var acError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            &acError)
        else {
            throw KeyBackendError.signingFailed("access control: \(acError.map { "\($0.takeRetainedValue())" } ?? "unknown")")
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        return make(publicX963: key.publicKey.x963Representation, keyData: key.dataRepresentation, comment: comment)
    }

    /// Rebuild from persisted key data. Reading the public key needs no auth.
    public static func from(keyData: Data, comment: String) throws -> SecureEnclaveKey {
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyData)
        return make(publicX963: key.publicKey.x963Representation, keyData: keyData, comment: comment)
    }

    private static func make(publicX963: Data, keyData: Data, comment: String) -> SecureEnclaveKey {
        let blob = SSHKeyFormat.ecdsaP256PublicBlob(x963Point: publicX963)
        return SecureEnclaveKey(
            id: KeyID(SSHKeyFormat.fingerprint(ofPublicKeyBlob: blob)),
            publicKey: SSHPublicKey(blob: blob, algorithm: .ecdsaP256, comment: comment),
            keyData: keyData)
    }

    public func sign(_ data: Data, context: SignContext) async throws -> SSHSignature {
        #if canImport(LocalAuthentication)
        let authContext = LAContext()
        authContext.localizedReason = context.host.map { "Sign in to \($0)" } ?? "Authorize SSH sign-in"
        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyData, authenticationContext: authContext)
        } catch {
            throw KeyBackendError.signingFailed("\(error)")
        }
        #else
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyData)
        #endif
        do {
            let signature = try key.signature(for: data)   // prompts for user presence
            let body = SSHKeyFormat.ecdsaSignatureBody(rawRS: signature.rawRepresentation)
            return SSHSignature(blob: SSHKeyFormat.signatureBlob(format: "ecdsa-sha2-nistp256", body: body))
        } catch {
            // CryptoKit surfaces a biometric cancel as a signing error.
            throw KeyBackendError.userCancelled
        }
    }
}
