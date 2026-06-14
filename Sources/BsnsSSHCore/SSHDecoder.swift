import Foundation

/// Reader counterpart to `SSHEncoder` for the SSH wire format (RFC 4251 §5).
/// Used to parse public-key blobs, signatures, and SSH-agent protocol
/// messages. Operates on a copied byte buffer so it is index-stable even when
/// constructed from a `Data` slice.
public struct SSHDecoder {
    public enum DecodeError: Error, Sendable {
        case truncated
        case invalidLength
    }

    private let bytes: [UInt8]
    private var offset = 0

    public init(_ data: Data) { self.bytes = [UInt8](data) }
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var isAtEnd: Bool { offset >= bytes.count }
    public var remaining: Int { bytes.count - offset }

    public mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw DecodeError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw DecodeError.truncated }
        let value = (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        offset += 4
        return value
    }

    public mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0 else { throw DecodeError.invalidLength }
        guard offset + count <= bytes.count else { throw DecodeError.truncated }
        defer { offset += count }
        return Data(bytes[offset ..< offset + count])
    }

    /// SSH `string`: a `uint32` length followed by that many bytes.
    public mutating func readString() throws -> Data {
        let length = Int(try readUInt32())
        return try readBytes(length)
    }

    /// SSH `string` decoded as UTF-8.
    public mutating func readStringUTF8() throws -> String {
        let data = try readString()
        guard let string = String(data: data, encoding: .utf8) else {
            throw DecodeError.invalidLength
        }
        return string
    }
}
