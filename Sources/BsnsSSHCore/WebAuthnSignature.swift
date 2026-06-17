import Foundation

/// Assembly of the `webauthn-sk-ecdsa-sha2-nistp256@openssh.com` SSH signature
/// (OpenSSH `PROTOCOL.u2f`). This is the signature variant a FIDO2 security key
/// produces when driven through a WebAuthn API (as Apple's AuthenticationServices
/// does): the authenticator signs over a `clientDataJSON` rather than the raw SSH
/// challenge, so the server needs the client data + origin to reconstruct and
/// verify. The public key is still an ordinary `sk-ecdsa-sha2-nistp256@openssh.com`
/// key (see `SSHKeyFormat.skEcdsaPublicBlob`); only the runtime signature differs.
///
/// Layout (`PROTOCOL.u2f`):
/// ```
/// string  "webauthn-sk-ecdsa-sha2-nistp256@openssh.com"
/// string  ecdsa_signature        # = string( mpint r || mpint s )
/// byte    flags
/// uint32  counter
/// string  origin
/// string  clientData             # the verbatim clientDataJSON bytes
/// string  extensions
/// ```
public enum WebAuthnSignature {
    public static let format = "webauthn-sk-ecdsa-sha2-nistp256@openssh.com"

    /// Build the complete signature blob. `derSignature` is the ASN.1 DER ECDSA
    /// signature Apple returns; `flags`/`counter` come from `authenticatorData`;
    /// `origin` is parsed from the clientDataJSON; `clientDataJSON` is forwarded
    /// verbatim (the server SHA-256s the exact bytes); `extensions` is usually
    /// empty.
    public static func signatureBlob(
        derSignature: Data,
        flags: UInt8,
        counter: UInt32,
        origin: String,
        clientDataJSON: Data,
        extensions: Data = Data()
    ) throws -> Data {
        let rawRS = try rawRS(fromDER: derSignature)
        return SSHEncoder.build {
            $0.writeString(format)
            $0.writeString(SSHKeyFormat.ecdsaSignatureBody(rawRS: rawRS))   // string( mpint r || mpint s )
            $0.writeByte(flags)
            $0.writeUInt32(counter)
            $0.writeString(origin)
            $0.writeString(clientDataJSON)
            $0.writeString(extensions)
        }
    }

    /// Parse an ASN.1 DER ECDSA-P256 signature (`SEQUENCE { INTEGER r, INTEGER s }`)
    /// into a fixed 64-byte `r || s` (each left-padded/trimmed to 32 bytes). DER
    /// integers are signed, so a high-bit value carries a leading 0x00 we strip;
    /// a short value we left-pad.
    public static func rawRS(fromDER der: Data) throws -> Data {
        let b = [UInt8](der)
        var i = 0
        func need(_ n: Int) throws { if i + n > b.count { throw KeyBackendError.signingFailed("bad DER signature") } }
        try need(2)
        guard b[i] == 0x30 else { throw KeyBackendError.signingFailed("bad DER signature (no SEQUENCE)") }
        i += 1
        // SEQUENCE length (short form is all P-256 needs; tolerate one long-form byte).
        if b[i] & 0x80 != 0 {
            let lenBytes = Int(b[i] & 0x7f); i += 1; try need(lenBytes)
            i += lenBytes
        } else {
            i += 1
        }
        func readInt() throws -> [UInt8] {
            try need(2)
            guard b[i] == 0x02 else { throw KeyBackendError.signingFailed("bad DER signature (no INTEGER)") }
            i += 1
            let len = Int(b[i]); i += 1
            try need(len)
            let v = Array(b[i ..< i + len]); i += len
            return v
        }
        let r = try fixed32(readInt())
        let s = try fixed32(readInt())
        return Data(r + s)
    }

    /// Strip DER sign-padding / left-pad a big-endian integer to exactly 32 bytes.
    private static func fixed32(_ value: [UInt8]) throws -> [UInt8] {
        var v = value
        while v.count > 1 && v.first == 0x00 { v.removeFirst() }   // drop leading zeros (incl. DER sign byte)
        if v.count > 32 { throw KeyBackendError.signingFailed("integer longer than 32 bytes") }
        if v.count < 32 { v = [UInt8](repeating: 0, count: 32 - v.count) + v }
        return v
    }
}
