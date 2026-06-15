package cc.bsns.ssh.core

import org.bouncycastle.crypto.ec.CustomNamedCurves
import org.bouncycastle.crypto.params.ECDomainParameters
import org.bouncycastle.crypto.params.ECPublicKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.ECDSASigner
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.math.BigInteger
import java.security.MessageDigest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Parity with the iOS `FileKeyTests`. */
class FileKeyTest {
    private val p256 = CustomNamedCurves.getByName("secp256r1").let { ECDomainParameters(it.curve, it.g, it.n, it.h) }

    @Test fun ed25519GeneratesSignsVerifies() {
        val key = FileKey.generate(KeyAlgorithm.ED25519, "test@host")
        assertEquals(KeyAlgorithm.ED25519, key.algorithm)
        assertTrue(key.canExport)
        assertFalse(key.requiresUserPresence)
        assertTrue(key.id.startsWith("SHA256:"))

        val msg = "authenticate me".toByteArray()
        val d = SshDecoder(key.sign(msg))
        assertEquals("ssh-ed25519", d.readStringUtf8())
        val body = d.readString()
        assertEquals(64, body.size)
        assertTrue(verifyEd25519(key.publicKey.blob, msg, body))
    }

    @Test fun ecdsaGeneratesSignsVerifies() {
        val key = FileKey.generate(KeyAlgorithm.ECDSA_P256)
        assertEquals(KeyAlgorithm.ECDSA_P256, key.algorithm)

        val msg = "hello".toByteArray()
        val d = SshDecoder(key.sign(msg))
        assertEquals("ecdsa-sha2-nistp256", d.readStringUtf8())
        assertTrue(verifyEcdsa(key.publicKey.blob, msg, d.readString()))
    }

    @Test fun roundTripsThroughExportedMaterialEd25519() {
        val key = FileKey.generate(KeyAlgorithm.ED25519)
        val restored = FileKey.from(KeyAlgorithm.ED25519, key.exportPrivateKeyMaterial())
        assertEquals(key.id, restored.id)
        assertContentEquals(key.publicKey.blob, restored.publicKey.blob)
    }

    @Test fun roundTripsThroughExportedMaterialEcdsa() {
        val key = FileKey.generate(KeyAlgorithm.ECDSA_P256)
        val restored = FileKey.from(KeyAlgorithm.ECDSA_P256, key.exportPrivateKeyMaterial())
        assertEquals(key.id, restored.id)
        assertContentEquals(key.publicKey.blob, restored.publicKey.blob)
        // The restored key signs verifiably with its re-derived public key.
        val sig = SshDecoder(restored.sign("x".toByteArray())); sig.readStringUtf8()
        assertTrue(verifyEcdsa(restored.publicKey.blob, "x".toByteArray(), sig.readString()))
    }

    @Test fun rejectsSecurityKeyAlgorithms() {
        assertFailsWith<KeyBackendException> { FileKey.generate(KeyAlgorithm.ECDSA_SK) }
        assertFailsWith<KeyBackendException> { FileKey.generate(KeyAlgorithm.ED25519_SK) }
    }

    private fun verifyEd25519(blob: ByteArray, msg: ByteArray, sig: ByteArray): Boolean {
        val d = SshDecoder(blob); d.readStringUtf8()
        val v = Ed25519Signer()
        v.init(false, Ed25519PublicKeyParameters(d.readString(), 0))
        v.update(msg, 0, msg.size)
        return v.verifySignature(sig)
    }

    private fun verifyEcdsa(blob: ByteArray, msg: ByteArray, body: ByteArray): Boolean {
        val bd = SshDecoder(blob); bd.readStringUtf8(); bd.readStringUtf8()
        val q = p256.curve.decodePoint(bd.readString())   // x963 0x04||X||Y
        val sig = SshDecoder(body)
        val r = BigInteger(1, sig.readString())            // mpint magnitude → positive
        val s = BigInteger(1, sig.readString())
        val signer = ECDSASigner()
        signer.init(false, ECPublicKeyParameters(q, p256))
        return signer.verifySignature(MessageDigest.getInstance("SHA-256").digest(msg), r, s)
    }
}
