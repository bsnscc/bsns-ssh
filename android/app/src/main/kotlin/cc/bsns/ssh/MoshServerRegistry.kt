package cc.bsns.ssh

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * Remembers the `mosh-server` processes this device started, so the ones it
 * abandons can be shut down by the next connect instead of sitting on the host
 * holding a PTY forever. Mirrors the iOS `MoshServerRegistry`.
 *
 * The rules are deliberately conservative: a PID is only *abandoned* when
 * nothing here can still be talking to it, and only abandoned PIDs are ever
 * signalled — that's what keeps a second live session to the same host (or a
 * session on another device) safe. Not secret: PIDs and host names.
 */
class MoshServerRegistry(context: Context) {
    private val prefs = context.getSharedPreferences("mosh_servers", Context.MODE_PRIVATE)

    /** `reapAttempts`: a reap can legitimately go unheeded — mosh-server only
     *  honours SIGUSR1 once it has been idle for `MOSH_SERVER_SIGNAL_TMOUT`, and a
     *  server abandoned seconds ago (a failed resume, say) hasn't been — so we
     *  retry on later connects instead of giving up after one shot. */
    private data class Record(val pid: Int, val hostKey: String, val sessionId: String?,
                              val startedAt: Long, val reapAttempts: Int = 0)

    companion object {
        fun hostKey(host: String, port: Int, user: String) = "$user@$host:$port"

        /** Records this old are dropped unreaped: the idle timeout every server is
         *  launched with has long since fired, and the PID has probably been
         *  recycled onto something else by now. */
        private const val MAX_AGE_MS = 7L * 24 * 3600 * 1000
        private const val MAX_RECORDS = 64
        private const val MAX_REAP_ATTEMPTS = 5
    }

    /** Every server recorded by a previous run of the app is orphaned by
     *  definition — its client's crypto state died with the process — so mark
     *  them all reapable. Call once at startup. */
    @Synchronized
    fun markAllAbandonedFromPreviousRun() =
        save(load().map { it.copy(sessionId = null) })

    /** This session is about to re-bootstrap: whatever server it held is now
     *  unreachable (a new client can't resume an old server). */
    @Synchronized
    fun abandon(sessionId: String) =
        save(load().map { if (it.sessionId == sessionId) it.copy(sessionId = null) else it })

    /** This particular server is unreachable (its client tore down without the
     *  server acknowledging a shutdown). Keyed by PID, not session, so it can't
     *  race a reconnect that has already recorded a *new* server for the same
     *  session — abandoning that one would have the next connect reap a live
     *  session. */
    @Synchronized
    fun abandon(pid: Int) =
        save(load().map { if (it.pid == pid) it.copy(sessionId = null) else it })

    /** The server exited cleanly (we shut it down over the mosh transport), so
     *  there's nothing left to reap. */
    @Synchronized
    fun forget(pid: Int) = save(load().filterNot { it.pid == pid })

    @Synchronized
    fun record(pid: Int, hostKey: String, sessionId: String) {
        if (pid <= 0) return
        val kept = load().filterNot { it.pid == pid && it.hostKey == hostKey }
        save(kept + Record(pid, hostKey, sessionId, System.currentTimeMillis()))
    }

    /** The abandoned PIDs on this host to ask to quit, retried across connects
     *  (see [Record.reapAttempts]) and dropped once they've had their attempts —
     *  we don't signal a PID forever, since by then it may belong to something
     *  else and the idle timeout has it covered anyway. */
    @Synchronized
    fun reapablePids(hostKey: String): List<Int> {
        val all = load()
        val due = all.filter { it.hostKey == hostKey && it.sessionId == null }
        if (due.isEmpty()) return emptyList()
        val bumped = due.map { it.copy(reapAttempts = it.reapAttempts + 1) }
            .filter { it.reapAttempts < MAX_REAP_ATTEMPTS }
        save((all - due.toSet()) + bumped)
        return due.map { it.pid }
    }

    private fun load(): List<Record> {
        val raw = prefs.getString("records", "[]") ?: "[]"
        val out = ArrayList<Record>()
        val arr = try { JSONArray(raw) } catch (e: Exception) { return out }
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val pid = o.optInt("pid", 0)
            val hostKey = o.optString("hostKey", "")
            if (pid <= 0 || hostKey.isEmpty()) continue
            out.add(Record(pid, hostKey,
                if (o.isNull("sessionId")) null else o.optString("sessionId").ifEmpty { null },
                o.optLong("startedAt", 0L), o.optInt("reapAttempts", 0)))
        }
        return out
    }

    private fun save(records: List<Record>) {
        val cutoff = System.currentTimeMillis() - MAX_AGE_MS
        val kept = records.filter { it.startedAt >= cutoff }.takeLast(MAX_RECORDS)
        val arr = JSONArray()
        for (r in kept) {
            arr.put(JSONObject().apply {
                put("pid", r.pid)
                put("hostKey", r.hostKey)
                if (r.sessionId != null) put("sessionId", r.sessionId)
                put("startedAt", r.startedAt)
                put("reapAttempts", r.reapAttempts)
            })
        }
        prefs.edit().putString("records", arr.toString()).apply()
    }
}
