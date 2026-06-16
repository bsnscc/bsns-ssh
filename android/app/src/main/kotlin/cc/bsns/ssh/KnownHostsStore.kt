package cc.bsns.ssh

import android.content.Context
import java.util.Base64

/** TOFU store: remembers each host's trusted host-key blob (base64) in prefs. */
class KnownHostsStore(context: Context) {
    private val prefs = context.getSharedPreferences("known_hosts", Context.MODE_PRIVATE)

    private fun key(host: String, port: Int) = if (port == 22) host else "[$host]:$port"

    fun trustedBlob(host: String, port: Int): ByteArray? =
        prefs.getString(key(host, port), null)?.let { Base64.getDecoder().decode(it) }

    fun trust(host: String, port: Int, blob: ByteArray) {
        prefs.edit().putString(key(host, port), Base64.getEncoder().encodeToString(blob)).apply()
    }

    fun forget(host: String, port: Int) {
        prefs.edit().remove(key(host, port)).apply()
    }
}
