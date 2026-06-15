import Foundation
import BsnsSSHCore

/// An SSH key whose private half lives on a YubiKey (PIV slot). Signing routes
/// through `YubiKeyCoordinator`, which opens a USB-C or NFC session and asks the
/// key to sign — the private key never leaves the token.
struct YubiKeyPIVKey: KeyBackend {
    let id: KeyID
    let algorithm: KeyAlgorithm = .ecdsaP256
    let publicKey: SSHPublicKey
    var canExport: Bool { false }
    var requiresUserPresence: Bool { true }
    let slot: UInt8

    static func make(publicBlob: Data, slot: UInt8, comment: String) -> YubiKeyPIVKey {
        YubiKeyPIVKey(
            id: KeyID(SSHKeyFormat.fingerprint(ofPublicKeyBlob: publicBlob)),
            publicKey: SSHPublicKey(blob: publicBlob, algorithm: .ecdsaP256, comment: comment),
            slot: slot)
    }

    func sign(_ data: Data, context: SignContext) async throws -> SSHSignature {
        let rawRS = try await YubiKeyCoordinator.shared.signRawRS(data, slot: slot)
        let body = SSHKeyFormat.ecdsaSignatureBody(rawRS: rawRS)
        return SSHSignature(blob: SSHKeyFormat.signatureBlob(format: "ecdsa-sha2-nistp256", body: body))
    }
}
