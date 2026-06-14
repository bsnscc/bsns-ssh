import Foundation
import Testing
@testable import BsnsSSHCore

@Suite("SSH wire decoding")
struct SSHDecoderTests {

    @Test("round-trips uint32 and string")
    func roundTrip() throws {
        let blob = SSHEncoder.build {
            $0.writeUInt32(0xDEAD_BEEF)
            $0.writeString("hello")
            $0.writeString(Data([1, 2, 3]))
        }
        var dec = SSHDecoder(blob)
        #expect(try dec.readUInt32() == 0xDEAD_BEEF)
        #expect(try dec.readStringUTF8() == "hello")
        #expect(try dec.readString() == Data([1, 2, 3]))
        #expect(dec.isAtEnd)
    }

    @Test("throws on truncation")
    func truncation() {
        var dec = SSHDecoder(Data([0, 0, 0, 5, 0x61])) // claims 5 bytes, has 1
        #expect(throws: SSHDecoder.DecodeError.self) {
            _ = try dec.readString()
        }
    }
}
