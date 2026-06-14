import Foundation

/// Minimal SSH wire-format encoder (RFC 4251 §5). Only the pieces the agent
/// and signature framing actually need: `uint32`, `string`, and the
/// sign-padded `mpint`.
///
/// `mpint` is the one with a footgun: it is a two's-complement big-endian
/// integer stored as a string, so a non-negative value whose top bit is set
/// must carry a leading 0x00 or it reads as negative — and unnecessary leading
/// zero bytes are forbidden. Getting this wrong makes public-key auth fail
/// silently, so it is covered by the RFC reference vectors in the tests.
public struct SSHEncoder {
    public private(set) var data = Data()

    public init() {}

    /// Append a 32-bit big-endian integer.
    public mutating func writeUInt32(_ value: UInt32) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    /// Append raw bytes with no length prefix.
    public mutating func writeBytes(_ bytes: Data) {
        data.append(bytes)
    }

    /// SSH `string`: a `uint32` length followed by that many bytes.
    public mutating func writeString(_ bytes: Data) {
        writeUInt32(UInt32(bytes.count))
        data.append(bytes)
    }

    /// SSH `string` from UTF-8 text.
    public mutating func writeString(_ string: String) {
        writeString(Data(string.utf8))
    }

    /// SSH `mpint`: a non-negative big-endian magnitude encoded as a string,
    /// with leading zero bytes stripped and a single 0x00 prepended when the
    /// high bit of the leading byte is set. Zero encodes as an empty string.
    public mutating func writeMPInt(_ magnitude: Data) {
        var bytes = [UInt8](magnitude)
        while bytes.first == 0x00 { bytes.removeFirst() }
        if bytes.isEmpty {
            writeUInt32(0)
            return
        }
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        writeString(Data(bytes))
    }
}

public extension SSHEncoder {
    /// Build a blob inline and return its bytes.
    static func build(_ body: (inout SSHEncoder) -> Void) -> Data {
        var encoder = SSHEncoder()
        body(&encoder)
        return encoder.data
    }
}
