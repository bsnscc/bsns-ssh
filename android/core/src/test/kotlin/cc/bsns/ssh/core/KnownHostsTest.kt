package cc.bsns.ssh.core

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Parity with the iOS `KnownHostsTests` + `SSHKeyFormat` blob layouts. */
class KnownHostsTest {
    private fun key(byte: Int) = HostKey("ssh-ed25519", ByteArray(32) { byte.toByte() })

    @Test fun firstContactIsUnknownWithFingerprint() {
        val store = KnownHosts()
        val result = store.verify("example.com", 22, key(0xAA))
        assertTrue(result is HostVerification.Unknown)
        assertTrue((result as HostVerification.Unknown).fingerprint.startsWith("SHA256:"))
    }

    @Test fun trustedKeyVerifiesAsTrusted() {
        val store = KnownHosts()
        store.trust("example.com", 22, key(0xAA))
        assertEquals(HostVerification.Trusted, store.verify("example.com", 22, key(0xAA)))
    }

    @Test fun changedKeyIsMismatch() {
        val store = KnownHosts()
        store.trust("example.com", 22, key(0xAA))
        assertTrue(store.verify("example.com", 22, key(0xBB)) is HostVerification.Mismatch)
    }

    @Test fun hostIdentityKeyedByHostAndNonDefaultPort() {
        val store = KnownHosts()
        store.trust("example.com", 2222, key(0xAA))
        assertNull(store.storedKey("example.com", 22))
        assertEquals(key(0xAA), store.storedKey("example.com", 2222))
        assertEquals("[example.com]:2222", KnownHosts.identifier("example.com", 2222))
        assertEquals("example.com", KnownHosts.identifier("example.com", 22))
    }

    // SSHKeyFormat blob layouts — decode them back to confirm structure.
    @Test fun ed25519BlobStructure() {
        val raw = ByteArray(32) { 0x11 }
        val d = SshDecoder(SshKeyFormat.ed25519PublicBlob(raw))
        assertEquals("ssh-ed25519", d.readStringUtf8())
        assertContentEquals(raw, d.readString())
        assertTrue(d.isAtEnd)
    }

    @Test fun ecdsaBlobStructure() {
        val q = ByteArray(65) { if (it == 0) 0x04 else 0x22 }
        val d = SshDecoder(SshKeyFormat.ecdsaP256PublicBlob(q))
        assertEquals("ecdsa-sha2-nistp256", d.readStringUtf8())
        assertEquals("nistp256", d.readStringUtf8())
        assertContentEquals(q, d.readString())
    }

    @Test fun fingerprintIsStableSha256Format() {
        val fp = SshKeyFormat.fingerprintOfPublicKeyBlob(ByteArray(32) { 0xAA.toByte() })
        assertTrue(fp.startsWith("SHA256:"))
        assertEquals(43, fp.removePrefix("SHA256:").length) // 32-byte digest, base64 unpadded
    }
}
