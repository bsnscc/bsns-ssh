package cc.bsns.ssh

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** A saved connection target. `jump` is an optional ProxyJump spec
 *  ("user@bastion[:port][,user@bastion2…]") used by the host-chain connect path;
 *  `group` is an optional folder label for organizing the saved list. */
data class SavedHost(
    val host: String,
    val port: Int,
    val user: String,
    val jump: String? = null,
    val group: String? = null,
    /** Id of the key to authenticate with; null (or unknown on load) falls back
     *  to the first key. */
    val keyId: String? = null,
) {
    val label: String get() = "$user@$host${if (port == 22) "" else ":$port"}"
}

/** Persists saved hosts in SharedPreferences as a JSON array (no extra deps). */
class HostStore(context: Context) {
    private val prefs = context.getSharedPreferences("hosts", Context.MODE_PRIVATE)

    fun load(): List<SavedHost> = try {
        val arr = JSONArray(prefs.getString("list", "[]"))
        (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            SavedHost(o.getString("host"), o.getInt("port"), o.getString("user"),
                o.optString("jump").ifEmpty { null }, o.optString("group").ifEmpty { null },
                o.optString("keyId").ifEmpty { null })
        }
    } catch (e: Exception) {
        emptyList()   // never crash the connect screen on a corrupt store
    }

    private fun save(hosts: List<SavedHost>) {
        val arr = JSONArray()
        hosts.forEach {
            val o = JSONObject().put("host", it.host).put("port", it.port).put("user", it.user)
            if (it.jump != null) o.put("jump", it.jump)
            if (it.group != null) o.put("group", it.group)
            if (it.keyId != null) o.put("keyId", it.keyId)
            arr.put(o)
        }
        // commit() (synchronous) so a saved host survives even if the process is
        // killed right after — apply()'s background write can be lost.
        prefs.edit().putString("list", arr.toString()).commit()
    }

    /** Add or update by label — re-saving an existing host refreshes its
     *  group / jump rather than silently keeping the old entry. */
    fun add(host: SavedHost): List<SavedHost> {
        val list = load().toMutableList()
        val i = list.indexOfFirst { it.label == host.label }
        if (i >= 0) list[i] = host else list.add(host)
        save(list)
        return list
    }

    fun remove(host: SavedHost): List<SavedHost> {
        val list = load().filter { it.label != host.label }
        save(list)
        return list
    }
}
