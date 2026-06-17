package cc.bsns.ssh.core

import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The openssh-key-v1 container we hand to libssh2 as `privatekeydata` must be
 *  byte-exact, or libssh2 can't parse the application/flags/key-handle back out.
 *  We can't link libssh2 in a JVM test, so we re-decode the structure ourselves
 *  and assert every field round-trips. */
class OpenSshSkKeyTest {
    @Test fun skEcdsaPemRoundTrips() {
        val point = ByteArray(65).also { it[0] = 0x04; it[1] = 0x11; it[64] = 0x99.toByte() }
        val handle = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
        val app = "ssh:bsns"
        val flags = 0x01

        val pem = OpenSshSkKey.ecdsaSkPem(point, app, handle, flags, comment = "bsns")

        assertTrue(pem.startsWith("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        assertTrue(pem.trimEnd().endsWith("-----END OPENSSH PRIVATE KEY-----"))

        val b64 = pem.lines()
            .filterNot { it.startsWith("-----") || it.isBlank() }
            .joinToString("")
        val body = Base64.getDecoder().decode(b64)

        val d = SshDecoder(body)
        // magic: "openssh-key-v1\0" (15 bytes, raw — not length-prefixed)
        assertContentEquals("openssh-key-v1\u0000".toByteArray(), d.readBytes(15))
        assertEquals("none", d.readStringUtf8())          // ciphername
        assertEquals("none", d.readStringUtf8())          // kdfname
        assertContentEquals(ByteArray(0), d.readString()) // kdfoptions
        assertEquals(1L, d.readUInt32())                  // nkeys

        // public blob == the authorized_keys blob the server stores
        assertContentEquals(SshKeyFormat.skEcdsaPublicBlob(point, app), d.readString())

        val priv = SshDecoder(d.readString())
        val c1 = priv.readUInt32(); val c2 = priv.readUInt32()
        assertEquals(c1, c2)                              // check ints match
        assertEquals(OpenSshSkKey.SK_ECDSA_TYPE, priv.readStringUtf8())
        assertEquals("nistp256", priv.readStringUtf8())
        assertContentEquals(point, priv.readString())
        assertEquals(app, priv.readStringUtf8())
        assertEquals(flags.toByte(), priv.readByte())
        assertContentEquals(handle, priv.readString())
        assertContentEquals(ByteArray(0), priv.readString())   // reserved
        assertEquals("bsns", priv.readStringUtf8())            // comment
        // remaining bytes are 1,2,3,… padding to an 8-byte boundary
        var expected = 1
        while (!priv.isAtEnd) assertEquals((expected++).toByte(), priv.readByte())
    }
}
