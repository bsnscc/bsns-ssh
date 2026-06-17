import Foundation

/// A minimal CBOR (RFC 8949) decoder — only what's needed to read a WebAuthn
/// attestation object and a COSE_Key (maps, byte/text strings, integers, arrays,
/// booleans, null). Definite-length items only (what authenticators emit). Kept
/// in-house rather than pulling a CBOR dependency, matching the project's
/// hand-rolled-codec approach (SSH wire, RSA DER, etc.).
public indirect enum CBORValue: Equatable {
    case uint(UInt64)
    case negint(Int64)        // the decoded (negative) value, e.g. -7
    case bytes(Data)
    case text(String)
    case array([CBORValue])
    case map([CBORPair])
    case bool(Bool)
    case null
    case undefined

    /// Look up a value in a CBOR map by an integer key. Positive keys are encoded
    /// as `.uint`, negative keys as `.negint` (COSE_Key uses both: 1=kty, 3=alg,
    /// -1=crv, -2=x, -3=y).
    public func value(intKey: Int) -> CBORValue? {
        guard case let .map(pairs) = self else { return nil }
        for p in pairs {
            switch p.key {
            case let .uint(u) where intKey >= 0 && UInt64(intKey) == u: return p.value
            case let .negint(n) where Int64(intKey) == n: return p.value
            default: continue
            }
        }
        return nil
    }

    /// Look up a value in a CBOR map by a text key.
    public func value(textKey: String) -> CBORValue? {
        guard case let .map(pairs) = self else { return nil }
        for p in pairs where p.key == .text(textKey) { return p.value }
        return nil
    }
}

public struct CBORPair: Equatable {
    public let key: CBORValue
    public let value: CBORValue
}

public enum CBORError: Error, Equatable {
    case truncated
    case unsupported(String)
}

public enum CBOR {
    /// Decode a single top-level CBOR item from `data`. Trailing bytes are ignored
    /// (an attestation object is one map; trailing data isn't expected but is harmless).
    public static func decode(_ data: Data) throws -> CBORValue {
        var r = Reader(bytes: [UInt8](data))
        return try r.value()
    }

    private struct Reader {
        let bytes: [UInt8]
        var i = 0

        mutating func byte() throws -> UInt8 {
            guard i < bytes.count else { throw CBORError.truncated }
            defer { i += 1 }
            return bytes[i]
        }

        mutating func take(_ n: Int) throws -> Data {
            guard n >= 0, i + n <= bytes.count else { throw CBORError.truncated }
            defer { i += n }
            return Data(bytes[i ..< i + n])
        }

        /// Read the argument that follows a major-type's 5-bit additional info.
        mutating func argument(_ info: UInt8) throws -> UInt64 {
            switch info {
            case 0...23: return UInt64(info)
            case 24: return UInt64(try byte())
            case 25:
                let b = try take(2); return UInt64(b[0]) << 8 | UInt64(b[1])
            case 26:
                let b = try take(4)
                return (0..<4).reduce(UInt64(0)) { $0 << 8 | UInt64(b[Int($1)]) }
            case 27:
                let b = try take(8)
                return (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(b[Int($1)]) }
            default:
                throw CBORError.unsupported("additional info \(info) (indefinite/reserved)")
            }
        }

        mutating func value() throws -> CBORValue {
            let initial = try byte()
            let major = initial >> 5
            let info = initial & 0x1f
            switch major {
            case 0:  // unsigned int
                return .uint(try argument(info))
            case 1:  // negative int = -1 - n
                let n = try argument(info)
                return .negint(-1 - Int64(n))
            case 2:  // byte string
                let len = Int(try argument(info))
                return .bytes(try take(len))
            case 3:  // text string
                let len = Int(try argument(info))
                let d = try take(len)
                return .text(String(decoding: d, as: UTF8.self))
            case 4:  // array
                let count = Int(try argument(info))
                var items: [CBORValue] = []; items.reserveCapacity(count)
                for _ in 0..<count { items.append(try value()) }
                return .array(items)
            case 5:  // map
                let count = Int(try argument(info))
                var pairs: [CBORPair] = []; pairs.reserveCapacity(count)
                for _ in 0..<count {
                    let k = try value(); let v = try value()
                    pairs.append(CBORPair(key: k, value: v))
                }
                return .map(pairs)
            case 7:  // simple values
                switch info {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22: return .null
                case 23: return .undefined
                default: throw CBORError.unsupported("simple/float \(info)")
                }
            default:
                throw CBORError.unsupported("major type \(major)")
            }
        }
    }
}
