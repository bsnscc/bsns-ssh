package cc.bsns.ssh

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import cc.bsns.ssh.core.FileKey
import cc.bsns.ssh.core.KeyAlgorithm
import cc.bsns.ssh.core.SshDecoder
import cc.bsns.ssh.core.SshKeyFormat
import cc.bsns.ssh.transport.KeystoreSigner
import java.security.KeyStore
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** A signer usable by the JNI bridge (it calls `sign([B): [B` by name). */
private const val HARDWARE_ALIAS = "bsns-app-key"

/** Wraps a software FileKey so the JNI sign callback gets the signature *body*
 *  (libssh2 frames the rest), matching what KeystoreSigner returns. */
class FileKeySigner(private val fileKey: FileKey) {
    val publicKeyBlob: ByteArray get() = fileKey.publicKey.blob
    fun sign(data: ByteArray): ByteArray {
        val full = fileKey.sign(data)        // string(format) || string(body)
        val d = SshDecoder(full)
        d.readString()                       // skip format
        return d.readString()                // body
    }
}

/** A key the app can authenticate with: hardware (Keystore), software (FileKey),
 *  or a YubiKey (PIV slot — signs over NFC/USB). */
class AppKey(
    val id: String,
    val label: String,
    val publicKeyBlob: ByteArray,
    val algorithm: String,   // wire name
    val hardware: Boolean,
    val signer: Any,         // object exposing sign([B): [B + publicKeyBlob
    val yubiKey: Boolean = false,
) {
    val fingerprint: String get() = SshKeyFormat.fingerprintOfPublicKeyBlob(publicKeyBlob)
    val authLine: String get() = "$algorithm ${Base64.getEncoder().encodeToString(publicKeyBlob)} bsns"
}

/** Software-key material at rest, AES-GCM-wrapped by a non-extractable Keystore key. */
private class SecureKeyStore(context: Context) {
    private val prefs = context.getSharedPreferences("soft_keys", Context.MODE_PRIVATE)
    private val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private val wrapAlias = "bsns-softkey-wrap"

    private fun wrapKey(): SecretKey {
        (ks.getEntry(wrapAlias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        kg.init(
            KeyGenParameterSpec.Builder(wrapAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return kg.generateKey()
    }

    fun save(algorithm: String, material: ByteArray, comment: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, wrapKey()) }
        val blob = cipher.iv + cipher.doFinal(material)
        val id = UUID.randomUUID().toString()
        prefs.edit().putString(id, "$algorithm|${Base64.getEncoder().encodeToString(blob)}|$comment").apply()
        return id
    }

    fun loadAll(): List<Triple<String, String, ByteArray>> =     // id, algorithm, material
        prefs.all.mapNotNull { (id, v) ->
            val parts = (v as? String)?.split("|", limit = 3) ?: return@mapNotNull null
            if (parts.size < 2) return@mapNotNull null
            val blob = Base64.getDecoder().decode(parts[1])
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                .apply { init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, blob.copyOfRange(0, 12))) }
            Triple(id, parts[0], cipher.doFinal(blob.copyOfRange(12, blob.size)))
        }

    fun delete(id: String) = prefs.edit().remove(id).apply()
}

/** Owns the available keys: the always-present hardware Keystore key + software keys. */
class KeyManager(context: Context) {
    private val hardwareSigner = KeystoreSigner(HARDWARE_ALIAS)
    private val store = SecureKeyStore(context)
    // Enrolled YubiKeys: just the public blob (the private key lives on the token).
    private val yubiPrefs = context.getSharedPreferences("yubikeys", Context.MODE_PRIVATE)

    fun keys(): List<AppKey> {
        val hw = AppKey(
            HARDWARE_ALIAS, "Hardware key (Keystore)", hardwareSigner.publicKeyBlob,
            "ecdsa-sha2-nistp256", hardware = true, signer = hardwareSigner,
        )
        val soft = store.loadAll().map { (id, algo, material) ->
            val fk = FileKey.from(KeyAlgorithm.fromWire(algo)!!, material, "bsns")
            val short = algo.removePrefix("ssh-").removePrefix("ecdsa-sha2-")
            AppKey(id, "Software key ($short)", fk.publicKey.blob, algo, hardware = false, signer = FileKeySigner(fk))
        }
        val yubi = yubiPrefs.all.mapNotNull { (id, v) ->
            val blob = (v as? String)?.let { Base64.getDecoder().decode(it) } ?: return@mapNotNull null
            AppKey(id, "YubiKey (PIV)", blob, "ecdsa-sha2-nistp256",
                hardware = true, signer = YubiKeyPivKey(blob), yubiKey = true)
        }
        return listOf(hw) + soft + yubi
    }

    /** Enroll a YubiKey (blocking — prompts a tap); returns the new key's id. */
    fun enrollYubiKey(pin: String): String {
        val blob = YubiKeyManager.enroll(pin)
        val id = SshKeyFormat.fingerprintOfPublicKeyBlob(blob)
        yubiPrefs.edit().putString(id, Base64.getEncoder().encodeToString(blob)).apply()
        return id
    }

    fun forgetYubiKey(id: String) = yubiPrefs.edit().remove(id).apply()

    fun generateSoftware(algorithm: KeyAlgorithm): String {
        val fk = FileKey.generate(algorithm, "bsns")
        return store.save(algorithm.wireName, fk.exportPrivateKeyMaterial(), "bsns")
    }

    fun deleteSoftware(id: String) = store.delete(id)

    /** Software keys as (wire-algorithm, private material, comment) for config export. */
    fun exportSoftware(): List<Triple<String, ByteArray, String>> =
        store.loadAll().map { (_, algo, material) -> Triple(algo, material, "bsns") }

    /** Re-import a software key from a config bundle (skips dup public keys). */
    fun importSoftware(algorithm: String, material: ByteArray, comment: String) {
        val algo = KeyAlgorithm.fromWire(algorithm) ?: return
        val blob = FileKey.from(algo, material, comment).publicKey.blob
        if (keys().any { it.publicKeyBlob.contentEquals(blob) }) return
        store.save(algorithm, material, comment)
    }
}
