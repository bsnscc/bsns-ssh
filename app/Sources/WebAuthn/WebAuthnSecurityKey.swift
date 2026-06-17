import Foundation
import BsnsSSHCore

/// An SSH key backed by a FIDO2 security key driven through Apple's WebAuthn API.
/// The public key is an ordinary `sk-ecdsa-sha2-nistp256@openssh.com` key; each
/// signature is the `webauthn-sk-…` variant assembled from a WebAuthn assertion
/// (`WebAuthnCoordinator`). The private key never leaves the token.
///
/// `sign` returns the COMPLETE signature blob (format string + webauthn trailer),
/// so the transport must authenticate via `libssh2_userauth_publickey_raw` and
/// send the blob verbatim — see `AgentSignBridge` / `SSHShell` (the `.ecdsaSK`
/// branch). This is why `SSHSignature.blob` here is NOT the usual
/// `string(format) || string(body)` shape.
struct WebAuthnSecurityKey: KeyBackend {
    let id: KeyID
    let algorithm: KeyAlgorithm = .ecdsaSK
    let publicKey: SSHPublicKey
    var canExport: Bool { false }
    var requiresUserPresence: Bool { true }
    /// The FIDO credential id, supplied to each assertion's allow-list.
    let credentialID: Data

    static func make(publicBlob: Data, credentialID: Data, comment: String) -> WebAuthnSecurityKey {
        WebAuthnSecurityKey(
            id: KeyID(SSHKeyFormat.fingerprint(ofPublicKeyBlob: publicBlob)),
            publicKey: SSHPublicKey(blob: publicBlob, algorithm: .ecdsaSK, comment: comment),
            credentialID: credentialID)
    }

    func sign(_ data: Data, context: SignContext) async throws -> SSHSignature {
        let blob = try await WebAuthnCoordinator.shared.assert(data: data, credentialID: credentialID)
        return SSHSignature(blob: blob)
    }
}
