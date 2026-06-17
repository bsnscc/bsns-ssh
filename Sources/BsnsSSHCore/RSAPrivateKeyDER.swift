import Foundation

/// Builds a PKCS#1 `RSAPrivateKey` DER — the representation `SecKeyCreateWithData`
/// (and FileKey's persisted `material`) expects — and unwraps the PEM containers
/// that hold one. Used by RSA key import.
///
/// OpenSSH's private-key format stores only n, e, d, iqmp, p, q, so the CRT
/// exponents dP = d mod (p−1) and dQ = d mod (q−1) must be recomputed. Swift has
/// no big-integer type, so a small fixed-purpose unsigned bignum (big-endian
/// byte arrays, modulo by feed-and-reduce) does just that. PKCS#1/PKCS#8 PEM
/// keys already carry the full structure, so those paths need no arithmetic.
enum RSAPrivateKeyDER {
    /// Assemble PKCS#1 RSAPrivateKey DER from the OpenSSH component mpints
    /// (raw, possibly carrying a leading 0x00 sign byte). `iqmp` = q⁻¹ mod p is
    /// supplied by OpenSSH; only dP and dQ are derived.
    static func fromComponents(n: Data, e: Data, d: Data, p: Data, q: Data, iqmp: Data) throws -> Data {
        let dBytes = [UInt8](d)
        let dp = Data(BigUInt.mod(dBytes, BigUInt.decrement([UInt8](p))))
        let dq = Data(BigUInt.mod(dBytes, BigUInt.decrement([UInt8](q))))
        let body = DER.integer(Data([0]))      // version = 0 (two-prime)
            + DER.integer(n) + DER.integer(e) + DER.integer(d)
            + DER.integer(p) + DER.integer(q)
            + DER.integer(dp) + DER.integer(dq) + DER.integer(iqmp)
        return DER.sequence(body)
    }

    /// Unwrap a PKCS#8 `PrivateKeyInfo` to the inner PKCS#1 RSAPrivateKey DER.
    /// `SEQUENCE { version, AlgorithmIdentifier, privateKey OCTET STRING }`.
    static func unwrapPKCS8(_ der: Data) throws -> Data {
        var s = DERReader(der)
        try s.enterSequence()
        _ = try s.readInteger()        // version
        try s.skipElement()            // AlgorithmIdentifier (assume rsaEncryption)
        return try s.readOctetString() // the PKCS#1 RSAPrivateKey
    }
}

/// Minimal DER writer for the shapes RSA private keys use.
private enum DER {
    static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    /// DER INTEGER from an unsigned big-endian magnitude: strip leading zeros,
    /// prepend 0x00 when the top bit is set (so it stays positive).
    static func integer(_ magnitude: Data) -> Data {
        var bytes = [UInt8](magnitude)
        while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data([0x02]) + length(bytes.count) + Data(bytes)
    }

    static func sequence(_ contents: Data) -> Data {
        Data([0x30]) + length(contents.count) + contents
    }
}

/// Minimal DER reader (only what PKCS#8 unwrap needs).
private struct DERReader {
    private let b: [UInt8]
    private var p = 0
    init(_ data: Data) { b = [UInt8](data) }

    private mutating func readTagLen(_ tag: UInt8) throws -> Int {
        guard p < b.count, b[p] == tag else { throw KeyImportError.corrupt }
        p += 1
        guard p < b.count else { throw KeyImportError.corrupt }
        let first = b[p]; p += 1
        if first & 0x80 == 0 { return Int(first) }
        let nbytes = Int(first & 0x7f)
        guard nbytes >= 1, nbytes <= 4, p + nbytes <= b.count else { throw KeyImportError.corrupt }
        var len = 0
        for _ in 0..<nbytes { len = (len << 8) | Int(b[p]); p += 1 }
        return len
    }

    mutating func enterSequence() throws { _ = try readTagLen(0x30) }

    mutating func readInteger() throws -> Data {
        let len = try readTagLen(0x02)
        guard p + len <= b.count else { throw KeyImportError.corrupt }
        defer { p += len }
        return Data(b[p ..< p + len])
    }

    mutating func readOctetString() throws -> Data {
        let len = try readTagLen(0x04)
        guard p + len <= b.count else { throw KeyImportError.corrupt }
        defer { p += len }
        return Data(b[p ..< p + len])
    }

    /// Skip one TLV element (any tag).
    mutating func skipElement() throws {
        guard p < b.count else { throw KeyImportError.corrupt }
        p += 1
        guard p < b.count else { throw KeyImportError.corrupt }
        let first = b[p]; p += 1
        var len: Int
        if first & 0x80 == 0 { len = Int(first) }
        else {
            let nbytes = Int(first & 0x7f)
            guard nbytes >= 1, nbytes <= 4, p + nbytes <= b.count else { throw KeyImportError.corrupt }
            len = 0
            for _ in 0..<nbytes { len = (len << 8) | Int(b[p]); p += 1 }
        }
        guard p + len <= b.count else { throw KeyImportError.corrupt }
        p += len
    }
}

/// Fixed-purpose unsigned big-integer over big-endian byte arrays. Only the ops
/// modular reduction needs: compare, subtract (a ≥ b), decrement, and `a mod m`.
private enum BigUInt {
    static func trim(_ a: [UInt8]) -> [UInt8] {
        var x = a
        while x.count > 1, x.first == 0 { x.removeFirst() }
        return x.isEmpty ? [0] : x
    }

    /// −1, 0, +1 for a vs b.
    static func cmp(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let x = trim(a), y = trim(b)
        if x.count != y.count { return x.count < y.count ? -1 : 1 }
        for i in 0..<x.count where x[i] != y[i] { return x[i] < y[i] ? -1 : 1 }
        return 0
    }

    /// a − b, requiring a ≥ b.
    static func sub(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        let x = trim(a), y = trim(b)
        var result = [UInt8](repeating: 0, count: x.count)
        var borrow = 0
        for i in 0..<x.count {
            let ai = Int(x[x.count - 1 - i])
            let bi = i < y.count ? Int(y[y.count - 1 - i]) : 0
            var diff = ai - bi - borrow
            if diff < 0 { diff += 256; borrow = 1 } else { borrow = 0 }
            result[x.count - 1 - i] = UInt8(diff)
        }
        return trim(result)
    }

    /// a − 1 (a ≥ 1).
    static func decrement(_ a: [UInt8]) -> [UInt8] { sub(a, [1]) }

    /// a mod m via feed-and-reduce: fold each byte of a into an accumulator
    /// (acc = acc·256 + byte) and subtract m until acc < m. No division needed;
    /// at most 255 subtractions per byte.
    static func mod(_ a: [UInt8], _ m: [UInt8]) -> [UInt8] {
        let mod = trim(m)
        var acc: [UInt8] = [0]
        for byte in trim(a) {
            acc.append(byte)             // acc·256 + byte
            acc = trim(acc)
            while cmp(acc, mod) >= 0 { acc = sub(acc, mod) }
        }
        return acc
    }
}
