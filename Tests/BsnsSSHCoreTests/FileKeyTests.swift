import Foundation
import CryptoKit
import Testing
@testable import BsnsSSHCore

@Suite("FileKey")
struct FileKeyTests {

    @Test("ed25519: generates, signs, and the signature verifies")
    func ed25519() async throws {
        let key = try FileKey.generate(algorithm: .ed25519, comment: "test@host")
        #expect(key.algorithm == .ed25519)
        #expect(key.canExport)
        #expect(!key.requiresUserPresence)
        #expect(key.id.rawValue.hasPrefix("SHA256:"))

        let message = Data("authenticate me".utf8)
        let signature = try await key.sign(message, context: SignContext(purpose: .sshUserAuth))

        // Signature blob is string(format) || string(body).
        var dec = SSHDecoder(signature.blob)
        #expect(try dec.readStringUTF8() == "ssh-ed25519")
        let body = try dec.readString()
        #expect(body.count == 64)

        // Recover the public key from the public blob and verify the body.
        let publicKey = try Self.ed25519PublicKey(from: key.publicKey.blob)
        #expect(publicKey.isValidSignature(body, for: message))
    }

    @Test("ecdsa p-256: generates, signs, and the signature verifies")
    func ecdsa() async throws {
        let key = try FileKey.generate(algorithm: .ecdsaP256)
        #expect(key.algorithm == .ecdsaP256)

        let message = Data("hello".utf8)
        let signature = try await key.sign(message, context: SignContext(purpose: .sshUserAuth))

        var dec = SSHDecoder(signature.blob)
        #expect(try dec.readStringUTF8() == "ecdsa-sha2-nistp256")
        let body = try dec.readString()

        // body = mpint(r) || mpint(s) -> reconstruct 64-byte r||s.
        var bodyDec = SSHDecoder(body)
        let r = try bodyDec.readString()
        let s = try bodyDec.readString()
        let rawRS = Self.fixed32(r) + Self.fixed32(s)

        let publicKey = try Self.ecdsaPublicKey(from: key.publicKey.blob)
        let ecdsaSignature = try P256.Signing.ECDSASignature(rawRepresentation: rawRS)
        #expect(publicKey.isValidSignature(ecdsaSignature, for: message))
    }

    @Test("round-trips through exported material")
    func roundTrip() throws {
        let key = try FileKey.generate(algorithm: .ed25519)
        let restored = try FileKey.from(algorithm: .ed25519, privateKeyMaterial: key.exportPrivateKeyMaterial())
        #expect(restored.id == key.id)
        #expect(restored.publicKey.blob == key.publicKey.blob)
    }

    @Test("rejects security-key algorithms")
    func rejectsSecurityKey() {
        #expect(throws: KeyBackendError.self) {
            try FileKey.generate(algorithm: .ecdsaSK)
        }
        #expect(throws: KeyBackendError.self) {
            try FileKey.generate(algorithm: .ed25519SK)
        }
    }

    // MARK: helpers

    static func ed25519PublicKey(from blob: Data) throws -> Curve25519.Signing.PublicKey {
        var dec = SSHDecoder(blob)
        _ = try dec.readStringUTF8() // "ssh-ed25519"
        return try Curve25519.Signing.PublicKey(rawRepresentation: try dec.readString())
    }

    static func ecdsaPublicKey(from blob: Data) throws -> P256.Signing.PublicKey {
        var dec = SSHDecoder(blob)
        _ = try dec.readStringUTF8() // "ecdsa-sha2-nistp256"
        _ = try dec.readStringUTF8() // "nistp256"
        return try P256.Signing.PublicKey(x963Representation: try dec.readString())
    }

    /// SSH mpint magnitude -> fixed 32-byte big-endian value.
    static func fixed32(_ mpint: Data) -> Data {
        var bytes = [UInt8](mpint)
        if bytes.first == 0x00 { bytes.removeFirst() } // drop sign pad
        while bytes.count < 32 { bytes.insert(0, at: 0) } // left-pad
        return Data(bytes.suffix(32))
    }
}
