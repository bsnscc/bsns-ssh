package cc.bsns.ssh.core

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

/** The sk-ecdsa (FIDO2 security-key) public-key blob layout — the wire format a
 *  server stores in authorized_keys, so it must be exact. */
class SkKeyFormatTest {
    @Test fun skEcdsaBlobIsWellFormed() {
        // A 65-byte uncompressed P-256 point (0x04 || X || Y) — content is arbitrary here.
        val point = ByteArray(65).also { it[0] = 0x04 }
        val blob = SshKeyFormat.skEcdsaPublicBlob(point, "ssh:bsns")

        val d = SshDecoder(blob)
        assertEquals("sk-ecdsa-sha2-nistp256@openssh.com", d.readStringUtf8())
        assertEquals("nistp256", d.readStringUtf8())
        assertContentEquals(point, d.readString())
        assertEquals("ssh:bsns", d.readStringUtf8())
    }
}
