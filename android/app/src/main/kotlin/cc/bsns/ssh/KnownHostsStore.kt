package cc.bsns.ssh

import android.content.Context
import cc.bsns.ssh.core.SshKeyFormat
import java.util.Base64

/** A trusted host entry, for the known-hosts manager. */
class KnownHostEntry(val id: String, val blob: ByteArray) {
    val fingerprint: String get() = SshKeyFormat.fingerprintOfPublicKeyBlob(blob)
}

/** TOFU store: remembers each host's trusted host-key blob (base64) in prefs. */
class KnownHostsStore(context: Context) {
    private val prefs = context.getSharedPreferences("known_hosts", Context.MODE_PRIVATE)

    private fun key(host: String, port: Int) = if (port == 22) host else "[$host]:$port"

    fun all(): List<KnownHostEntry> =
        prefs.all.entries.mapNotNull { (k, v) ->
            (v as? String)?.let { KnownHostEntry(k, Base64.getDecoder().decode(it)) }
        }.sortedBy { it.id }

    fun forgetId(id: String) {
        prefs.edit().remove(id).apply()
    }

    /** Trust by the raw store key (host or "[host]:port"), for config import. */
    fun trustRaw(id: String, blob: ByteArray) {
        prefs.edit().putString(id, Base64.getEncoder().encodeToString(blob)).apply()
    }

    fun trustedBlob(host: String, port: Int): ByteArray? =
        prefs.getString(key(host, port), null)?.let { Base64.getDecoder().decode(it) }

    fun trust(host: String, port: Int, blob: ByteArray) {
        prefs.edit().putString(key(host, port), Base64.getEncoder().encodeToString(blob)).apply()
    }

    fun forget(host: String, port: Int) {
        prefs.edit().remove(key(host, port)).apply()
    }
}
