import XCTest
import Security
@testable import BsnsSSHCore

final class RSAKeyTests: XCTestCase {
    /// A generated RSA key must produce a well-formed `ssh-rsa` public blob:
    /// string("ssh-rsa") || mpint(e) || mpint(n).
    func testGeneratedPublicBlobIsWellFormed() throws {
        let key = try FileKey.generate(algorithm: .rsa, comment: "rsa-test")
        XCTAssertEqual(key.algorithm, .rsa)

        var dec = SSHDecoder(key.publicKey.blob)
        XCTAssertEqual(try dec.readString(), Data("ssh-rsa".utf8))
        let e = try dec.readString()
        let n = try dec.readString()
        XCTAssertFalse(e.isEmpty)
        // 3072-bit modulus ≈ 384 bytes (+ a leading 0x00 sign byte).
        XCTAssertGreaterThan(n.count, 384)
        XCTAssertEqual(key.publicKey.algorithm, .rsa)
        XCTAssertTrue(key.canExport)
    }

    /// Reconstructing from persisted material reproduces the same public blob.
    func testRoundTripFromMaterial() throws {
        let key = try FileKey.generate(algorithm: .rsa)
        let restored = try FileKey.from(algorithm: .rsa, privateKeyMaterial: key.exportPrivateKeyMaterial())
        XCTAssertEqual(restored.publicKey.blob, key.publicKey.blob)
        XCTAssertEqual(restored.id, key.id)
    }

    /// The signature body must be a valid PKCS#1 v1.5 RSA signature over the
    /// right hash, and the blob's format string must match the requested algorithm.
    func testSignaturesVerifyPerAlgorithm() async throws {
        let key = try FileKey.generate(algorithm: .rsa)
        let pub = SecKeyCopyPublicKey(try RSAKeySupport.privateKey(fromMaterial: key.exportPrivateKeyMaterial()))!
        let message = Data("the quick brown fox".utf8)

        let cases: [(RSASignatureAlgorithm, String, SecKeyAlgorithm)] = [
            (.sha1, "ssh-rsa", .rsaSignatureMessagePKCS1v15SHA1),
            (.sha256, "rsa-sha2-256", .rsaSignatureMessagePKCS1v15SHA256),
            (.sha512, "rsa-sha2-512", .rsaSignatureMessagePKCS1v15SHA512),
        ]
        for (alg, wireName, secAlg) in cases {
            let sig = try await key.sign(message, context: SignContext(purpose: .sshUserAuth, rsaAlgorithm: alg))
            var dec = SSHDecoder(sig.blob)
            XCTAssertEqual(try dec.readString(), Data(wireName.utf8), "format string for \(wireName)")
            let body = try dec.readString()
            var err: Unmanaged<CFError>?
            let ok = SecKeyVerifySignature(pub, secAlg, message as CFData, body as CFData, &err)
            XCTAssertTrue(ok, "\(wireName) signature should verify (\(String(describing: err?.takeRetainedValue())))")
        }
    }
}
