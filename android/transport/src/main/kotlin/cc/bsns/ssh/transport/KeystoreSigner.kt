package cc.bsns.ssh.transport

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import cc.bsns.ssh.core.SshKeyFormat
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

/**
 * A non-extractable ECDSA P-256 key in the Android Keystore. The private key is
 * generated in, and never leaves, the device's secure key store — StrongBox on
 * devices that have it, otherwise the TEE (the emulator has no StrongBox).
 * Signing happens there; the key is never exported.
 *
 * Note: signing is NOT gated on a per-use biometric/credential prompt — the app
 * lock gates the UI, not each signature. (Per-sign user auth would require a
 * prompt on every connection and a key migration; not enabled.)
 *
 * `sign` is invoked from the native libssh2 sign callback (by name/signature),
 * returning the SSH ECDSA signature body `mpint(r) || mpint(s)`.
 */
class KeystoreSigner(alias: String) {
    private val privateKey: PrivateKey
    val publicKeyBlob: ByteArray

    init {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!ks.containsAlias(alias)) {
            fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .apply { if (strongBox && android.os.Build.VERSION.SDK_INT >= 28) setIsStrongBoxBacked(true) }
                .build()
            val kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            try {                                   // prefer StrongBox; fall back to the TEE
                kpg.initialize(spec(true)); kpg.generateKeyPair()
            } catch (e: Exception) {
                kpg.initialize(spec(false)); kpg.generateKeyPair()
            }
        }
        val entry = ks.getEntry(alias, null) as KeyStore.PrivateKeyEntry
        privateKey = entry.privateKey
        val ec = entry.certificate.publicKey as ECPublicKey
        val x963 = byteArrayOf(0x04) + fixed32(ec.w.affineX) + fixed32(ec.w.affineY)
        publicKeyBlob = SshKeyFormat.ecdsaP256PublicBlob(x963)
    }

    /** Called from JNI: SHA-256 + ECDSA in the Keystore, framed as the SSH body. */
    fun sign(data: ByteArray): ByteArray {
        val sig = Signature.getInstance("SHA256withECDSA")
        sig.initSign(privateKey)
        sig.update(data)
        val (r, s) = derToRS(sig.sign())
        return SshKeyFormat.ecdsaSignatureBody(fixed32(r) + fixed32(s))
    }

    private fun fixed32(n: BigInteger): ByteArray {
        var b = n.toByteArray()
        if (b.size > 32) b = b.copyOfRange(b.size - 32, b.size)
        if (b.size < 32) b = ByteArray(32 - b.size) + b
        return b
    }

    /** Parse a DER ECDSA signature: SEQUENCE { INTEGER r, INTEGER s } (P-256: short lengths). */
    private fun derToRS(der: ByteArray): Pair<BigInteger, BigInteger> {
        var i = 0
        require(der[i++].toInt() == 0x30) { "bad DER seq" }
        if (der[i].toInt() and 0x80 != 0) i += 1 + (der[i].toInt() and 0x7f) else i++  // seq length
        require(der[i++].toInt() == 0x02) { "bad DER r" }
        val rlen = der[i++].toInt() and 0xFF
        val r = BigInteger(der.copyOfRange(i, i + rlen)); i += rlen
        require(der[i++].toInt() == 0x02) { "bad DER s" }
        val slen = der[i++].toInt() and 0xFF
        val s = BigInteger(der.copyOfRange(i, i + slen))
        return r to s
    }
}
