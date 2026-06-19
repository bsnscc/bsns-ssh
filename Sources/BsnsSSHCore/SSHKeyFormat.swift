import Foundation
import CryptoKit

/// SSH public-key blob, signature blob, and fingerprint construction. Keeps
/// the wire-format details in one place so backends just supply key material.
public enum SSHKeyFormat {
    /// OpenSSH-style key fingerprint: `SHA256:` + unpadded base64 of the
    /// SHA-256 of the public-key blob.
    public static func fingerprint(ofPublicKeyBlob blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }

    /// `ssh-ed25519` public-key blob: `string("ssh-ed25519") || string(A)`.
    public static func ed25519PublicBlob(rawPublicKey: Data) -> Data {
        SSHEncoder.build {
            $0.writeString("ssh-ed25519")
            $0.writeString(rawPublicKey)
        }
    }

    /// `ecdsa-sha2-nistp256` public-key blob:
    /// `string(type) || string("nistp256") || string(Q)` where `Q` is the
    /// uncompressed point `0x04 || X || Y` (x9.63).
    public static func ecdsaP256PublicBlob(x963Point: Data) -> Data {
        SSHEncoder.build {
            $0.writeString("ecdsa-sha2-nistp256")
            $0.writeString("nistp256")
            $0.writeString(x963Point)
        }
    }

    /// `sk-ecdsa-sha2-nistp256@openssh.com` (FIDO2 security-key) public-key blob:
    /// `string(type) || string("nistp256") || string(Q) || string(application)`.
    /// `Q` is the uncompressed point `0x04 || X || Y`; `application` is the FIDO
    /// relying-party id (rpId) baked into the key. Native CTAP2 on iOS/Android
    /// uses the same public-blob and signature format; legacy iOS keys enrolled
    /// through Apple's WebAuthn API keep this public blob but sign with the
    /// `webauthn-sk-...` variant at runtime.
    public static func skEcdsaPublicBlob(x963Point: Data, application: String) -> Data {
        SSHEncoder.build {
            $0.writeString("sk-ecdsa-sha2-nistp256@openssh.com")
            $0.writeString("nistp256")
            $0.writeString(x963Point)
            $0.writeString(application)
        }
    }

    /// `ssh-rsa` public-key blob: `string("ssh-rsa") || mpint(e) || mpint(n)`
    /// (RFC 4253 §6.6 — the exponent comes before the modulus).
    public static func rsaPublicBlob(exponent: Data, modulus: Data) -> Data {
        SSHEncoder.build {
            $0.writeString("ssh-rsa")
            $0.writeMPInt(exponent)
            $0.writeMPInt(modulus)
        }
    }

    /// A complete SSH signature blob: `string(format) || string(body)`. This
    /// is the canonical representation (also what the SSH-agent protocol
    /// returns). The libssh2 publickey callback wants only `body`, which it
    /// re-frames itself.
    public static func signatureBlob(format: String, body: Data) -> Data {
        SSHEncoder.build {
            $0.writeString(format)
            $0.writeString(body)
        }
    }

    /// ECDSA signature body from a 64-byte `r || s`: `mpint(r) || mpint(s)`.
    public static func ecdsaSignatureBody(rawRS: Data) -> Data {
        SSHEncoder.build {
            $0.writeMPInt(Data(rawRS.prefix(32)))
            $0.writeMPInt(Data(rawRS.suffix(32)))
        }
    }

    /// Native OpenSSH security-key ECDSA signature:
    /// `string(format) || string(mpint(r) || mpint(s)) || byte(flags) || uint32(counter)`.
    /// This is a complete signature blob that must be sent verbatim by transports
    /// using the raw public-key path.
    public static func skEcdsaSignatureBlob(rawRS: Data, flags: UInt8, counter: UInt32) -> Data {
        SSHEncoder.build {
            $0.writeString("sk-ecdsa-sha2-nistp256@openssh.com")
            $0.writeString(ecdsaSignatureBody(rawRS: rawRS))
            $0.writeByte(flags)
            $0.writeUInt32(counter)
        }
    }
}
