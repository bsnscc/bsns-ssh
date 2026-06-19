import Foundation
import BsnsSSHCore

/// An SSH key backed by a native CTAP2 FIDO2 resident credential. New iOS keys
/// use the same OpenSSH `ssh:bsns` application string as Android, so one physical
/// credential can produce the same public key and native `sk-ecdsa` signatures
/// on either platform.
struct Fido2SecurityKey: KeyBackend {
    let id: KeyID
    let algorithm: KeyAlgorithm = .ecdsaSK
    let publicKey: SSHPublicKey
    var canExport: Bool { false }
    var requiresUserPresence: Bool { true }

    let credentialID: Data
    let application: String

    static func make(publicBlob: Data, credentialID: Data, application: String, comment: String) -> Fido2SecurityKey {
        Fido2SecurityKey(
            id: KeyID(SSHKeyFormat.fingerprint(ofPublicKeyBlob: publicBlob)),
            publicKey: SSHPublicKey(blob: publicBlob, algorithm: .ecdsaSK, comment: comment),
            credentialID: credentialID,
            application: application)
    }

    func sign(_ data: Data, context: SignContext) async throws -> SSHSignature {
        let blob = try await Fido2Coordinator.shared.assert(data: data,
                                                            credentialID: credentialID,
                                                            application: application)
        return SSHSignature(blob: blob)
    }
}
