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
 * A non-extractable ECDSA P-256 key in the Android Keystore. The private key
 * never leaves the secure hardware (TEE on the emulator; StrongBox on capable
 * devices via `setIsStrongBoxBacked`). Signing happens in hardware; this is the
 * Android analogue of the iOS Secure Enclave backend.
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
            val kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            kpg.initialize(
                KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    // On a real device add .setIsStrongBoxBacked(true) +
                    // .setUserAuthenticationRequired(true) for biometric gating.
                    .build()
            )
            kpg.generateKeyPair()
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
