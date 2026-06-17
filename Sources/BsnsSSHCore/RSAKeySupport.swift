import Foundation
import Security

/// RSA software-key primitives, built on the Security framework (CryptoKit has
/// no RSA). Used by `FileKey` for the `ssh-rsa` algorithm — the compatibility
/// path for legacy gear (older networking equipment) that predates Ed25519 /
/// ECDSA. Keys are generated transiently and serialized as PKCS#1 DER; nothing
/// is stored in the system keychain (FileKey owns persistence + encryption).
enum RSAKeySupport {
    /// 3072-bit ≈ 128-bit security — a sane modern default that even old gear
    /// accepts. (2048 is the floor; we pick 3072 to age better.)
    static let defaultBits = 3072

    /// Generate a fresh RSA key. Returns the `ssh-rsa` public blob and the PKCS#1
    /// private-key DER that FileKey persists / syncs.
    static func generate(bits: Int = defaultBits) throws -> (publicBlob: Data, material: Data) {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bits,
        ]
        var err: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw KeyBackendError.signingFailed("RSA keygen: \(cfError(err))")
        }
        return (try publicBlob(from: priv), try externalRepresentation(of: priv))
    }

    /// Rebuild the `ssh-rsa` public blob from persisted PKCS#1 private material.
    static func publicBlob(fromMaterial material: Data) throws -> Data {
        try publicBlob(from: try privateKey(fromMaterial: material))
    }

    /// PKCS#1 v1.5 sign `data` with the algorithm's hash. Returns the inner
    /// signature body — the `string(body)` that the SSH signature blob and the
    /// libssh2 userauth callback expect.
    static func sign(material: Data, data: Data, algorithm: RSASignatureAlgorithm) throws -> Data {
        let key = try privateKey(fromMaterial: material)
        let secAlg: SecKeyAlgorithm
        switch algorithm {
        case .sha1:   secAlg = .rsaSignatureMessagePKCS1v15SHA1
        case .sha256: secAlg = .rsaSignatureMessagePKCS1v15SHA256
        case .sha512: secAlg = .rsaSignatureMessagePKCS1v15SHA512
        }
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, secAlg, data as CFData, &err) else {
            throw KeyBackendError.signingFailed("RSA sign: \(cfError(err))")
        }
        return sig as Data
    }

    // MARK: internals

    /// Load a private `SecKey` from PKCS#1 RSAPrivateKey DER (what
    /// `SecKeyCopyExternalRepresentation` emits for an RSA private key).
    static func privateKey(fromMaterial material: Data) throws -> SecKey {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(material as CFData, attrs as CFDictionary, &err) else {
            throw KeyBackendError.signingFailed("RSA load: \(cfError(err))")
        }
        return key
    }

    private static func externalRepresentation(of key: SecKey) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(key, &err) else {
            throw KeyBackendError.signingFailed("RSA export: \(cfError(err))")
        }
        return der as Data
    }

    private static func publicBlob(from priv: SecKey) throws -> Data {
        guard let pub = SecKeyCopyPublicKey(priv) else {
            throw KeyBackendError.signingFailed("RSA public-key derivation failed")
        }
        // SecKeyCopyExternalRepresentation emits PKCS#1 RSAPublicKey DER for RSA:
        // SEQUENCE { modulus INTEGER, publicExponent INTEGER }.
        let (modulus, exponent) = try parsePKCS1PublicKey(externalRepresentation(of: pub))
        return SSHKeyFormat.rsaPublicBlob(exponent: exponent, modulus: modulus)
    }

    /// Parse `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`.
    /// Returns the raw INTEGER contents (a DER positive integer may carry a leading
    /// 0x00, which `writeMPInt` normalizes).
    static func parsePKCS1PublicKey(_ der: Data) throws -> (modulus: Data, exponent: Data) {
        var dec = DERScanner(der)
        try dec.expect(0x30)            // SEQUENCE
        _ = try dec.readLength()
        let modulus = try dec.readInteger()
        let exponent = try dec.readInteger()
        return (modulus, exponent)
    }

    private static func cfError(_ e: Unmanaged<CFError>?) -> String {
        guard let e = e?.takeRetainedValue() else { return "unknown error" }
        return (e as Error).localizedDescription
    }
}

/// Tiny DER reader for the one shape we parse here: a SEQUENCE of INTEGERs.
private struct DERScanner {
    private let b: [UInt8]
    private var p = 0
    init(_ data: Data) { b = [UInt8](data) }

    mutating func expect(_ tag: UInt8) throws {
        guard p < b.count, b[p] == tag else {
            throw KeyBackendError.signingFailed("DER: expected tag 0x\(String(tag, radix: 16))")
        }
        p += 1
    }

    mutating func readLength() throws -> Int {
        guard p < b.count else { throw KeyBackendError.signingFailed("DER: truncated length") }
        let first = b[p]; p += 1
        if first & 0x80 == 0 { return Int(first) }
        let n = Int(first & 0x7f)
        guard n >= 1, n <= 4, p + n <= b.count else { throw KeyBackendError.signingFailed("DER: bad length") }
        var len = 0
        for _ in 0..<n { len = (len << 8) | Int(b[p]); p += 1 }
        return len
    }

    mutating func readInteger() throws -> Data {
        try expect(0x02)
        let len = try readLength()
        guard p + len <= b.count else { throw KeyBackendError.signingFailed("DER: truncated integer") }
        defer { p += len }
        return Data(b[p ..< p + len])
    }
}
