package cc.bsns.ssh.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

class BadEnvelopeException : Exception()
class BadPassphraseException : Exception()

/**
 * The encrypted config-bundle envelope — Kotlin port of the iOS `ConfigCrypto`.
 * This is the **cross-platform sync contract**: a bundle pushed from iOS must
 * decrypt on Android and vice-versa.
 *
 * - KDF: PBKDF2-SHA256, 210k iterations, 16-byte salt → 32-byte key.
 * - AEAD: AES-256-GCM; `combined` = nonce(12) ‖ ciphertext ‖ tag(16), matching
 *   CryptoKit's `AES.GCM.SealedBox.combined`.
 * - Envelope JSON: `{format, iterations, salt(base64), combined(base64)}`.
 *
 * Verified against a real iOS-produced vector in the tests.
 */
object ConfigEnvelope {
    private const val ITERATIONS = 210_000
    private const val FORMAT = "bsns-config-aesgcm-v1"
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    @Serializable
    private data class Envelope(
        val format: String = FORMAT,
        val iterations: Int,
        val salt: String,      // base64
        val combined: String,  // base64: nonce ‖ ciphertext ‖ tag
    )

    fun encrypt(plaintext: ByteArray, passphrase: String): ByteArray {
        val salt = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val key = deriveKey(passphrase, salt, ITERATIONS)
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        val combined = iv + cipher.doFinal(plaintext)   // doFinal returns ciphertext ‖ tag
        val env = Envelope(iterations = ITERATIONS, salt = b64(salt), combined = b64(combined))
        return json.encodeToString(env).toByteArray(Charsets.UTF_8)
    }

    fun decrypt(data: ByteArray, passphrase: String): ByteArray {
        val env = try {
            json.decodeFromString(Envelope.serializer(), data.toString(Charsets.UTF_8))
        } catch (e: Exception) {
            throw BadEnvelopeException()
        }
        val salt = unb64(env.salt)
        val combined = unb64(env.combined)
        // Validate the untrusted envelope before expensive KDF work (parity with iOS).
        if (env.format != FORMAT || salt.size != 16 || env.iterations !in 1..10_000_000 || combined.size < 28) {
            throw BadEnvelopeException()
        }
        val key = deriveKey(passphrase, salt, env.iterations)
        val iv = combined.copyOfRange(0, 12)
        val ctAndTag = combined.copyOfRange(12, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        return try { cipher.doFinal(ctAndTag) } catch (e: Exception) { throw BadPassphraseException() }
    }

    /** True if `data` is an encrypted envelope (vs. plain JSON config). */
    fun isEncrypted(data: ByteArray): Boolean = try {
        json.decodeFromString(Envelope.serializer(), data.toString(Charsets.UTF_8))
        true
    } catch (e: Exception) {
        false
    }

    private fun deriveKey(passphrase: String, salt: ByteArray, iterations: Int): ByteArray {
        val spec = PBEKeySpec(passphrase.toCharArray(), salt, iterations, 256)
        return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
    }

    private fun b64(b: ByteArray): String = Base64.getEncoder().encodeToString(b)
    private fun unb64(s: String): ByteArray = Base64.getDecoder().decode(s)
}
