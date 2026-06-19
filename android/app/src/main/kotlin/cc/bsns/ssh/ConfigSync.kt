package cc.bsns.ssh

import android.content.Context
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.documentfile.provider.DocumentFile
import cc.bsns.ssh.core.ConfigEnvelope
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Auto-sync settings: a user-chosen folder (any Files provider — iCloud Drive,
 * Drive, Dropbox, local) and a passphrase, both under the user's control. The
 * passphrase is wrapped by a non-extractable Keystore key and never leaves the
 * device in the clear; the provider only ever sees the AES-GCM ciphertext bundle.
 */
class SyncStore(context: Context) {
    private val prefs = context.getSharedPreferences("sync", Context.MODE_PRIVATE)
    private val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private val wrapAlias = "bsns-sync-wrap"

    private fun wrapKey(): SecretKey {
        (ks.getEntry(wrapAlias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        kg.init(KeyGenParameterSpec.Builder(wrapAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        return kg.generateKey()
    }

    val enabled: Boolean get() = folderUri != null && passphrase != null

    var folderUri: String?
        get() = prefs.getString("folder", null)
        private set(v) { prefs.edit().putString("folder", v).apply() }

    var passphrase: String?
        get() = prefs.getString("pass", null)?.let { stored ->
            runCatching {
                val blob = Base64.getDecoder().decode(stored)
                Cipher.getInstance("AES/GCM/NoPadding")
                    .apply { init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, blob.copyOfRange(0, 12))) }
                    .doFinal(blob.copyOfRange(12, blob.size)).toString(Charsets.UTF_8)
            }.getOrNull()
        }
        private set(v) {
            if (v == null) { prefs.edit().remove("pass").apply(); return }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, wrapKey()) }
            val blob = cipher.iv + cipher.doFinal(v.toByteArray(Charsets.UTF_8))
            prefs.edit().putString("pass", Base64.getEncoder().encodeToString(blob)).apply()
        }

    /** Hash of the last bundle we pushed/pulled, so we skip redundant writes. */
    var lastHash: String?
        get() = prefs.getString("hash", null)
        set(v) { prefs.edit().putString("hash", v).apply() }

    fun configure(folder: String, pass: String) { folderUri = folder; passphrase = pass; lastHash = null }
    fun clear() { prefs.edit().clear().apply() }
}

/**
 * The auto-sync engine. Pushes an encrypted bundle to the chosen folder and
 * pulls + merges it back. Additive merge (never deletes), so a synced device
 * gains the union — matches the manual import semantics. Same on-disk format as
 * the manual backup, so the two interoperate.
 */
object ConfigSync {
    // Shared cross-platform sync filename (matches iOS SyncStore.fileName), so a
    // folder synced between an iOS and an Android device points at one file.
    private const val FILE = "bsns-ssh-sync.json"
    // The original Android-only name; still read so a device that synced before
    // the rename keeps finding its bundle.
    private const val LEGACY_FILE = "bsns-config-aesgcm-v1.json"

    private fun sha256(b: ByteArray): String =
        Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(b))

    private fun folder(context: Context, store: SyncStore): DocumentFile? =
        store.folderUri?.let { DocumentFile.fromTreeUri(context, Uri.parse(it)) }?.takeIf { it.canWrite() }

    /** Write the current config (incl. software keys) to the sync folder, encrypted.
     *  Skips the write if nothing changed since the last sync. Returns a status string. */
    fun push(context: Context): String {
        val store = SyncStore(context)
        val pass = store.passphrase ?: return "sync not set up"
        val dir = folder(context, store) ?: return "sync folder unavailable"
        val plain = ConfigBundle.build(context, includeKeys = true)
        val hash = sha256(plain)
        if (hash == store.lastHash) return "already up to date"
        val sealed = ConfigEnvelope.encrypt(plain, pass)
        // Always write the canonical (cross-platform) name so iOS finds it, even
        // if a legacy-named file is still present from before the rename.
        val file = dir.findFile(FILE) ?: dir.createFile("application/json", FILE) ?: return "couldn't write to the folder"
        context.contentResolver.openOutputStream(file.uri, "wt")?.use { it.write(sealed) } ?: return "write failed"
        store.lastHash = hash
        return "synced up"
    }

    /** Read + merge the folder's bundle into this device (additive). Returns the
     *  applied summary, or null if there's nothing to pull / it's unchanged. */
    fun pull(context: Context): ConfigBundle.Applied? {
        val store = SyncStore(context)
        val pass = store.passphrase ?: return null
        val dir = folder(context, store) ?: return null
        val file = (dir.findFile(FILE) ?: dir.findFile(LEGACY_FILE))?.takeIf { it.isFile } ?: return null
        val sealed = context.contentResolver.openInputStream(file.uri)?.use { it.readBytes() } ?: return null
        val plain = runCatching { ConfigEnvelope.decrypt(sealed, pass) }.getOrNull() ?: return null
        val o = ConfigBundle.parse(plain)
        // The user configured this folder + passphrase, so it's a trusted source:
        // merge every category. Snippets come across too, but apply() forces their
        // runOnConnect off — synced snippets never silently auto-execute.
        val sel = ConfigBundle.Selection(hosts = true, knownHosts = true, settings = true,
                                         keys = true, snippets = true)
        return ConfigBundle.apply(context, o, sel)
    }
}
