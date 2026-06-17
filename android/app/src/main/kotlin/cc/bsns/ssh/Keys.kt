package cc.bsns.ssh

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import cc.bsns.ssh.core.FileKey
import cc.bsns.ssh.core.KeyAlgorithm
import cc.bsns.ssh.core.RsaSignatureAlgorithm
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
        // libssh2 may frame an ssh-rsa key's signature as rsa-sha2-256/512 based on
        // the server's server-sig-algs, and the to-be-signed blob carries that name.
        // Parse it so the RSA body uses the matching hash (a SHA-1 body under an
        // rsa-sha2-* frame is rejected by modern servers). Ignored for non-RSA keys.
        val full = fileKey.sign(data, rsaAlgorithmFor(data))   // string(format) || string(body)
        val d = SshDecoder(full)
        d.readString()                       // skip format
        return d.readString()                // body
    }

    /// Read the public-key-algorithm name from an SSH userauth signed blob
    /// (RFC 4252 §7) and map it to the RSA hash it implies.
    private fun rsaAlgorithmFor(data: ByteArray): RsaSignatureAlgorithm = try {
        val d = SshDecoder(data)
        d.readString()   // session id
        d.readByte()     // SSH_MSG_USERAUTH_REQUEST
        d.readString()   // user
        d.readString()   // service
        d.readString()   // "publickey"
        d.readByte()     // has-signature bool
        when (String(d.readString(), Charsets.UTF_8)) {
            "rsa-sha2-512" -> RsaSignatureAlgorithm.SHA512
            "rsa-sha2-256" -> RsaSignatureAlgorithm.SHA256
            else -> RsaSignatureAlgorithm.SHA1
        }
    } catch (e: Exception) {
        RsaSignatureAlgorithm.SHA1
    }
}

/** A key the app can authenticate with: hardware (Keystore), software (FileKey),
 *  a YubiKey PIV slot (signs over NFC/USB), or a FIDO2 security key (sk-ecdsa). */
class AppKey(
    val id: String,
    val label: String,
    val publicKeyBlob: ByteArray,
    val algorithm: String,   // wire name
    val hardware: Boolean,
    val signer: Any,         // object exposing sign([B): [B (or signSk for fido) + publicKeyBlob
    val yubiKey: Boolean = false,
    val builtIn: Boolean = false,   // the always-present device Keystore key (not deletable)
    val fido: Boolean = false,      // FIDO2 sk key — uses libssh2's sk-userauth path (direct only)
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
    // Enrolled FIDO2 (sk) keys: "base64(publicBlob)|base64(credentialId)|flags".
    // The credential's private key lives on the authenticator; we keep only the
    // public blob + handle the sk userauth path needs.
    private val fidoPrefs = context.getSharedPreferences("fidokeys", Context.MODE_PRIVATE)

    fun keys(): List<AppKey> {
        // Label by the key's *actual* backing, not an assumption.
        val hw = AppKey(
            HARDWARE_ALIAS, "Device key (${hardwareSigner.backing.label})", hardwareSigner.publicKeyBlob,
            "ecdsa-sha2-nistp256", hardware = hardwareSigner.isHardwareBacked, signer = hardwareSigner,
            builtIn = true,
        )
        val soft = store.loadAll().map { (id, algo, material) ->
            val fk = FileKey.from(KeyAlgorithm.fromWire(algo)!!, material, "bsns")
            val short = algo.removePrefix("ssh-").removePrefix("ecdsa-sha2-")
            AppKey(id, "Software key ($short)", fk.publicKey.blob, algo, hardware = false, signer = FileKeySigner(fk))
        }
        val yubi = yubiPrefs.all.mapNotNull { (id, v) ->
            val blob = (v as? String)?.let { Base64.getDecoder().decode(it) } ?: return@mapNotNull null
            AppKey(id, "Smart card (PIV)", blob, "ecdsa-sha2-nistp256",
                hardware = true, signer = YubiKeyPivKey(blob), yubiKey = true)
        }
        val fido = fidoPrefs.all.mapNotNull { (id, v) ->
            val parts = (v as? String)?.split("|") ?: return@mapNotNull null
            if (parts.size < 3) return@mapNotNull null
            val blob = Base64.getDecoder().decode(parts[0])
            val credId = Base64.getDecoder().decode(parts[1])
            val flags = parts[2].toIntOrNull() ?: 0x01
            // Recover the EC point + application from the stored public blob:
            // string(type) | string("nistp256") | string(point) | string(application).
            val d = SshDecoder(blob)
            d.readString(); d.readString()                 // type, curve
            val point = d.readString()
            val application = d.readStringUtf8()
            val signer = FidoSkKey(blob, credId, application, point, flags)
            AppKey(id, "FIDO2 security key", blob, "sk-ecdsa-sha2-nistp256@openssh.com",
                hardware = true, signer = signer, fido = true)
        }
        return listOf(hw) + soft + yubi + fido
    }

    /** Enroll a YubiKey (blocking — prompts a tap); returns the new key's id. */
    fun enrollYubiKey(pin: String): String {
        val blob = YubiKeyManager.enroll(pin)
        val id = SshKeyFormat.fingerprintOfPublicKeyBlob(blob)
        yubiPrefs.edit().putString(id, Base64.getEncoder().encodeToString(blob)).apply()
        return id
    }

    fun forgetYubiKey(id: String) = yubiPrefs.edit().remove(id).apply()

    /** Enroll a FIDO2 security key (blocking — prompts a tap); returns the new key's id.
     *  Creates a resident sk-ecdsa credential under the fixed "ssh:bsns" application. */
    fun enrollFido(pin: String): String {
        val e = FidoKeyManager.enroll(pin)
        val id = SshKeyFormat.fingerprintOfPublicKeyBlob(e.publicBlob)
        val v = listOf(
            Base64.getEncoder().encodeToString(e.publicBlob),
            Base64.getEncoder().encodeToString(e.credentialId),
            e.flags.toString(),
        ).joinToString("|")
        fidoPrefs.edit().putString(id, v).apply()
        return id
    }

    fun forgetFido(id: String) = fidoPrefs.edit().remove(id).apply()

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
