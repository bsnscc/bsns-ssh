package cc.bsns.ssh.core

import kotlin.test.Test
import kotlin.test.assertContentEquals

/**
 * Parity vectors shared with the iOS `SSHWireTests` (RFC 4251 §5). If these pass
 * identically on both platforms, the Kotlin and Swift encoders agree byte-for-byte
 * — the cross-platform contract for signature framing and the config envelope.
 */
class SshWireTest {
    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    @Test fun uint32IsBigEndian() {
        val e = SshEncoder(); e.writeUInt32(0x01020304)
        assertContentEquals(bytes(0x01, 0x02, 0x03, 0x04), e.data)
    }

    @Test fun stringIsLengthPrefixed() {
        val e = SshEncoder(); e.writeString("abc")
        assertContentEquals(bytes(0x00, 0x00, 0x00, 0x03, 0x61, 0x62, 0x63), e.data)
    }

    @Test fun emptyStringIsZeroLength() {
        val e = SshEncoder(); e.writeString(ByteArray(0))
        assertContentEquals(bytes(0, 0, 0, 0), e.data)
    }

    @Test fun mpintZeroIsEmptyString() {
        val e = SshEncoder(); e.writeMPInt(ByteArray(0))
        assertContentEquals(bytes(0, 0, 0, 0), e.data)
        val e2 = SshEncoder(); e2.writeMPInt(bytes(0x00, 0x00))
        assertContentEquals(bytes(0, 0, 0, 0), e2.data)
    }

    @Test fun mpintHighBitClearIsUnpadded() {
        // RFC 4251 §5 reference value 0x9a378f9b2e332a7.
        val e = SshEncoder(); e.writeMPInt(bytes(0x09, 0xa3, 0x78, 0xf9, 0xb2, 0xe3, 0x32, 0xa7))
        assertContentEquals(bytes(0, 0, 0, 8, 0x09, 0xa3, 0x78, 0xf9, 0xb2, 0xe3, 0x32, 0xa7), e.data)
    }

    @Test fun mpintHighBitSetGetsSignByte() {
        val e = SshEncoder(); e.writeMPInt(bytes(0x80))
        assertContentEquals(bytes(0, 0, 0, 2, 0x00, 0x80), e.data)
        val e2 = SshEncoder(); e2.writeMPInt(bytes(0xde, 0xad, 0xbe, 0xef))
        assertContentEquals(bytes(0, 0, 0, 5, 0x00, 0xde, 0xad, 0xbe, 0xef), e2.data)
    }

    @Test fun mpintStripsLeadingZeros() {
        val e = SshEncoder(); e.writeMPInt(bytes(0x00, 0x00, 0x12, 0x34))
        assertContentEquals(bytes(0, 0, 0, 2, 0x12, 0x34), e.data)
    }

    @Test fun ecdsaSignatureBodyFramesRandSAsMpints() {
        val r = bytes(0x80) + ByteArray(31) { 0x11 }
        val s = bytes(0x22) + ByteArray(31) { 0x33 }
        val body = SshEncoder.build {
            it.writeMPInt(r)
            it.writeMPInt(s)
        }
        val expected = SshEncoder()
        expected.writeUInt32(33)
        expected.writeBytes(byteArrayOf(0x00) + r)
        expected.writeUInt32(32)
        expected.writeBytes(s)
        assertContentEquals(expected.data, body)
    }
}
