package cc.bsns.ssh.transport

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import cc.bsns.ssh.core.SshKeyFormat
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

/** Authorizes a single use of an auth-required Keystore key. The app layer
 *  implements this with a biometric prompt bound to the [Signature] (a
 *  `BiometricPrompt.CryptoObject`). Called on the background SSH thread, so it
 *  must block until the user authenticates and throw on cancel/failure. */
fun interface KeyAuthorizer {
    fun authorize(reason: String, signature: Signature)
}

/**
 * A non-extractable ECDSA P-256 key in the Android Keystore. The private key is
 * generated in, and never leaves, the device's secure key store — StrongBox on
 * devices that have it, otherwise the TEE (the emulator has no StrongBox).
 * Signing happens there; the key is never exported.
 *
 * By default signing is NOT gated on a per-use biometric/credential prompt — the
 * app lock gates the UI, not each signature. When constructed with [requireAuth]
 * = true the key is generated requiring per-use user authentication, and every
 * `sign` is gated behind [authorizer]'s biometric prompt (the opt-in
 * "biometric-protected device key"). Requiring auth is a property of the key at
 * generation; it can't be added to an existing key, so the protected key is a
 * separate, additional key rather than a flag flipped on the everyday one.
 *
 * `sign` is invoked from the native libssh2 sign callback (by name/signature),
 * returning the SSH ECDSA signature body `mpint(r) || mpint(s)`.
 */
class KeystoreSigner(alias: String, requireAuth: Boolean = false) {
    companion object {
        /** Set by the app layer to drive the per-use biometric prompt for
         *  auth-required keys. Null in a headless/test context, where signing such
         *  a key fails closed rather than silently skipping the prompt. */
        @JvmStatic
        var authorizer: KeyAuthorizer? = null
    }

    private val privateKey: PrivateKey
    val publicKeyBlob: ByteArray
    /** True if this key requires per-use user authentication (set at generation). */
    val requiresAuth: Boolean

    /** The key's actual backing, inspected from KeyInfo — so the UI states the
     *  truth ("StrongBox" / "TEE" / "software") instead of assuming hardware. */
    enum class Backing(val label: String) {
        STRONGBOX("StrongBox"), TEE("hardware (TEE)"), SOFTWARE("software"), UNKNOWN("Keystore")
    }
    val backing: Backing
    val isHardwareBacked: Boolean get() = backing == Backing.STRONGBOX || backing == Backing.TEE

    init {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!ks.containsAlias(alias)) {
            fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .apply {
                    if (strongBox && android.os.Build.VERSION.SDK_INT >= 28) setIsStrongBoxBacked(true)
                    if (requireAuth) {
                        setUserAuthenticationRequired(true)
                        // Don't invalidate the key when the user enrolls a new
                        // fingerprint: this is a per-use presence gate, not an
                        // enrollment binding, and invalidation would mean lockout
                        // from every server trusting the key. The prompt still
                        // requires a strong (class-3) biometric each use.
                        setInvalidatedByBiometricEnrollment(false)
                        if (android.os.Build.VERSION.SDK_INT >= 30) {
                            setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                        } else {
                            @Suppress("DEPRECATION")
                            setUserAuthenticationValidityDurationSeconds(-1)  // per-use (CryptoObject) auth
                        }
                    }
                }
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
        backing = detectBacking(privateKey)
        requiresAuth = detectRequiresAuth(privateKey)
    }

    /** Read back whether the Keystore enforces per-use authentication for this key. */
    private fun detectRequiresAuth(key: PrivateKey): Boolean = try {
        val info = KeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
            .getKeySpec(key, KeyInfo::class.java) as KeyInfo
        info.isUserAuthenticationRequired
    } catch (e: Exception) {
        false
    }

    /** Ask the Keystore what actually backs the key (API 31+ gives the precise
     *  security level; older devices only tell us secure-hardware yes/no). */
    private fun detectBacking(key: PrivateKey): Backing = try {
        val info = KeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
            .getKeySpec(key, KeyInfo::class.java) as KeyInfo
        if (android.os.Build.VERSION.SDK_INT >= 31) {
            when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> Backing.STRONGBOX
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> Backing.TEE
                KeyProperties.SECURITY_LEVEL_SOFTWARE -> Backing.SOFTWARE
                else -> Backing.UNKNOWN
            }
        } else {
            @Suppress("DEPRECATION")
            if (info.isInsideSecureHardware) Backing.TEE else Backing.SOFTWARE
        }
    } catch (e: Exception) {
        Backing.UNKNOWN
    }

    /** Called from JNI: SHA-256 + ECDSA in the Keystore, framed as the SSH body.
     *  For an auth-required key the signature is authorized per use via a biometric
     *  prompt (CryptoObject); this blocks the calling SSH thread until the user
     *  authenticates, and throws if they cancel or it fails. */
    fun sign(data: ByteArray): ByteArray {
        val sig = Signature.getInstance("SHA256withECDSA")
        sig.initSign(privateKey)
        if (requiresAuth) {
            val auth = authorizer
                ?: throw IllegalStateException("This key requires a biometric prompt, which isn't available here.")
            auth.authorize("Authorize use of your SSH key", sig)
        }
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
