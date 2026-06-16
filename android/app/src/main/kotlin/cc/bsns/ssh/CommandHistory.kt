package cc.bsns.ssh

import android.content.Context
import org.json.JSONArray

/**
 * A local, on-device history of commands you've run — the privacy-respecting
 * counterpart to cloud "AI autocomplete": suggestions come from your own past
 * commands, nothing is uploaded. Stays on the device (deliberately NOT synced).
 */
class CommandHistory(context: Context) {
    private val prefs = context.getSharedPreferences("cmd_history", Context.MODE_PRIVATE)
    private val cap = 300

    /** Most-recent first. */
    fun all(): List<String> = try {
        val arr = JSONArray(prefs.getString("list", "[]"))
        (0 until arr.length()).map { arr.getString(it) }
    } catch (e: Exception) { emptyList() }

    /** Record a run command: move-to-front, de-duplicated, capped. */
    fun record(command: String) {
        val cmd = command.trim()
        if (cmd.isEmpty() || cmd.length > 1000) return
        val list = ArrayList(all())
        list.remove(cmd)
        list.add(0, cmd)
        while (list.size > cap) list.removeAt(list.size - 1)
        prefs.edit().putString("list", JSONArray(list).toString()).apply()
    }

    fun clear() = prefs.edit().remove("list").apply()

    /** History entries that extend `prefix` (prefix match, excluding an exact hit). */
    fun suggestions(prefix: String, limit: Int = 3): List<String> {
        val p = prefix.trimStart()
        if (p.length < 2) return emptyList()
        return all().asSequence()
            .filter { it.length > p.length && it.startsWith(p) }
            .distinct()
            .take(limit)
            .toList()
    }
}
