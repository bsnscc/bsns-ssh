package cc.bsns.ssh

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** A saved connection target. */
data class SavedHost(val host: String, val port: Int, val user: String) {
    val label: String get() = "$user@$host${if (port == 22) "" else ":$port"}"
}

/** Persists saved hosts in SharedPreferences as a JSON array (no extra deps). */
class HostStore(context: Context) {
    private val prefs = context.getSharedPreferences("hosts", Context.MODE_PRIVATE)

    fun load(): List<SavedHost> {
        val arr = JSONArray(prefs.getString("list", "[]"))
        return (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            SavedHost(o.getString("host"), o.getInt("port"), o.getString("user"))
        }
    }

    private fun save(hosts: List<SavedHost>) {
        val arr = JSONArray()
        hosts.forEach { arr.put(JSONObject().put("host", it.host).put("port", it.port).put("user", it.user)) }
        prefs.edit().putString("list", arr.toString()).apply()
    }

    fun add(host: SavedHost): List<SavedHost> {
        val list = load().toMutableList()
        if (list.none { it.label == host.label }) list.add(host)
        save(list)
        return list
    }

    fun remove(host: SavedHost): List<SavedHost> {
        val list = load().filter { it.label != host.label }
        save(list)
        return list
    }
}
