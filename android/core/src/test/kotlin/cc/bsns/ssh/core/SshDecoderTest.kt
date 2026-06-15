package cc.bsns.ssh.core

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** Parity with the iOS `SSHDecoderTests`. */
class SshDecoderTest {
    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    @Test fun roundTripsUint32AndString() {
        val blob = SshEncoder.build {
            it.writeUInt32(0xDEADBEEF)
            it.writeString("hello")
            it.writeString(bytes(1, 2, 3))
        }
        val d = SshDecoder(blob)
        assertEquals(0xDEADBEEFL, d.readUInt32())
        assertEquals("hello", d.readStringUtf8())
        assertContentEquals(bytes(1, 2, 3), d.readString())
        assertTrue(d.isAtEnd)
    }

    @Test fun throwsOnTruncation() {
        val d = SshDecoder(bytes(0, 0, 0, 5, 0x61)) // claims 5 bytes, has 1
        assertFailsWith<SshDecoder.DecodeException> { d.readString() }
    }
}
