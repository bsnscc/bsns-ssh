import Foundation
import Testing
@testable import BsnsSSHCore

@Suite("SSH wire encoding (RFC 4251 §5)")
struct SSHWireTests {

    @Test("uint32 is big-endian")
    func uint32() {
        var enc = SSHEncoder()
        enc.writeUInt32(0x0102_0304)
        #expect(enc.data == Data([0x01, 0x02, 0x03, 0x04]))
    }

    @Test("string is length-prefixed")
    func string() {
        var enc = SSHEncoder()
        enc.writeString("abc")
        #expect(enc.data == Data([0x00, 0x00, 0x00, 0x03, 0x61, 0x62, 0x63]))
    }

    @Test("empty string is a zero length")
    func emptyString() {
        var enc = SSHEncoder()
        enc.writeString(Data())
        #expect(enc.data == Data([0, 0, 0, 0]))
    }

    @Test("mpint zero encodes as an empty string")
    func mpintZero() {
        var enc = SSHEncoder()
        enc.writeMPInt(Data())
        #expect(enc.data == Data([0, 0, 0, 0]))

        var enc2 = SSHEncoder()
        enc2.writeMPInt(Data([0x00, 0x00])) // leading zeros collapse to zero
        #expect(enc2.data == Data([0, 0, 0, 0]))
    }

    @Test("mpint with high bit clear is unpadded")
    func mpintNoPad() {
        // RFC 4251 §5 reference value 0x9a378f9b2e332a7.
        var enc = SSHEncoder()
        enc.writeMPInt(Data([0x09, 0xa3, 0x78, 0xf9, 0xb2, 0xe3, 0x32, 0xa7]))
        #expect(enc.data == Data([0, 0, 0, 8, 0x09, 0xa3, 0x78, 0xf9, 0xb2, 0xe3, 0x32, 0xa7]))
    }

    @Test("mpint with high bit set gets a 0x00 sign byte")
    func mpintSignPad() {
        var enc = SSHEncoder()
        enc.writeMPInt(Data([0x80]))
        #expect(enc.data == Data([0, 0, 0, 2, 0x00, 0x80]))

        var enc2 = SSHEncoder()
        enc2.writeMPInt(Data([0xde, 0xad, 0xbe, 0xef]))
        #expect(enc2.data == Data([0, 0, 0, 5, 0x00, 0xde, 0xad, 0xbe, 0xef]))
    }

    @Test("mpint strips unnecessary leading zeros")
    func mpintStripLeadingZeros() {
        var enc = SSHEncoder()
        enc.writeMPInt(Data([0x00, 0x00, 0x12, 0x34]))
        #expect(enc.data == Data([0, 0, 0, 2, 0x12, 0x34]))
    }

    @Test("ecdsa signature body frames r and s as mpints")
    func ecdsaSignatureBody() {
        // r leads with 0x80 (high bit set → padded to 33 bytes); s does not.
        let r = Data([0x80] + Array(repeating: 0x11, count: 31))
        let s = Data([0x22] + Array(repeating: 0x33, count: 31))

        let body = SSHEncoder.build {
            $0.writeMPInt(r)
            $0.writeMPInt(s)
        }

        var expected = SSHEncoder()
        expected.writeUInt32(33)
        expected.writeBytes(Data([0x00]) + r)
        expected.writeUInt32(32)
        expected.writeBytes(s)

        #expect(body == expected.data)
    }
}
