package cc.bsns.ssh

import android.content.Context
import cc.bsns.ssh.core.SshDecoder
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

/**
 * A portable snapshot of the app's config: saved hosts, trusted host keys,
 * terminal settings, and optionally the software private keys. Field names
 * overlap the iOS `ConfigBundle` where the concepts match, so the shared
 * (cross-verified) `ConfigEnvelope` crypto carries a bundle between devices.
 * Android↔Android is verified; full iOS↔Android bundle parity is by-design.
 */
object ConfigBundle {
    class Summary(val hosts: Int, val knownHosts: Int, val keys: Int, val hasSettings: Boolean)

    /** Serialise the current config to JSON bytes (keys only when opted in). */
    fun build(context: Context, includeKeys: Boolean): ByteArray {
        val root = JSONObject().put("version", 1)

        val hosts = JSONArray()
        HostStore(context).load().forEach {
            hosts.put(JSONObject().put("host", it.host).put("port", it.port).put("user", it.user))
        }
        root.put("hosts", hosts)

        val known = JSONObject()
        KnownHostsStore(context).all().forEach {
            known.put(it.id, Base64.getEncoder().encodeToString(it.blob))
        }
        root.put("knownHosts", known)

        val s = SettingsStore(context)
        root.put("settings", JSONObject()
            .put("fontSize", s.fontSize)
            .put("scrollback", s.scrollback)
            .put("cursorBlink", s.cursorBlink)
            .put("keepAwake", s.keepAwake)
            .put("showKeyBar", s.showKeyBar))

        if (includeKeys) {
            val keys = JSONArray()
            KeyManager(context).exportSoftware().forEach { (algo, material, comment) ->
                keys.put(JSONObject()
                    .put("algorithm", algo)
                    .put("material", Base64.getEncoder().encodeToString(material))
                    .put("comment", comment))
            }
            root.put("keys", keys)
        }
        return root.toString().toByteArray(Charsets.UTF_8)
    }

    fun parse(data: ByteArray): JSONObject = JSONObject(String(data, Charsets.UTF_8))

    fun summarize(o: JSONObject) = Summary(
        hosts = o.optJSONArray("hosts")?.length() ?: 0,
        knownHosts = o.optJSONObject("knownHosts")?.length() ?: 0,
        keys = o.optJSONArray("keys")?.length() ?: 0,
        hasSettings = o.has("settings"),
    )

    /** Which categories the user opted to import. Hosts/settings are low-risk;
     *  trusted host keys and private keys are explicit opt-ins. */
    class Selection(
        val hosts: Boolean,
        val knownHosts: Boolean,
        val settings: Boolean,
        val keys: Boolean,
    )

    /** What an import actually merged — so the UI reports the truth, not "imported". */
    class Applied(val hosts: Int, val knownHosts: Int, val keys: Int, val settings: Boolean) {
        val isEmpty: Boolean get() = hosts == 0 && knownHosts == 0 && keys == 0 && !settings
        val summary: String get() {
            val parts = buildList {
                if (hosts > 0) add("$hosts host(s)")
                if (knownHosts > 0) add("$knownHosts trusted key(s)")
                if (keys > 0) add("$keys private key(s)")
                if (settings) add("settings")
            }
            return if (parts.isEmpty()) "nothing applied" else "imported ${parts.joinToString(", ")}"
        }
    }

    /** Merge the opted-in categories into the local stores (additive; dups skipped).
     *  Every untrusted field is validated/clamped before it touches a store, and the
     *  caller is told exactly what was applied. Malformed entries are skipped, not fatal. */
    fun apply(context: Context, o: JSONObject, sel: Selection): Applied {
        var hosts = 0; var known = 0; var keys = 0; var settings = false

        if (sel.hosts) o.optJSONArray("hosts")?.let { arr ->
            val hostStore = HostStore(context)
            for (i in 0 until arr.length()) {
                val h = arr.optJSONObject(i) ?: continue
                val host = h.optString("host").trim()
                val port = h.optInt("port", 22)
                val user = h.optString("user").trim()
                if (host.isEmpty() || user.isEmpty() || port !in 1..65535) continue
                hostStore.add(SavedHost(host, port, user)); hosts++
            }
        }
        if (sel.knownHosts) o.optJSONObject("knownHosts")?.let { kh ->
            val store = KnownHostsStore(context)
            kh.keys().forEach { id ->
                val blob = runCatching { Base64.getDecoder().decode(kh.getString(id)) }.getOrNull()
                if (id.isNotBlank() && blob != null && isPlausibleHostKey(blob)) {
                    store.trustRaw(id, blob); known++
                }
            }
        }
        if (sel.settings) o.optJSONObject("settings")?.let { s ->
            val st = SettingsStore(context)
            st.fontSize = s.optInt("fontSize", st.fontSize).coerceIn(8, 30)
            st.scrollback = s.optInt("scrollback", st.scrollback).coerceIn(100, 100_000)
            st.cursorBlink = s.optBoolean("cursorBlink", st.cursorBlink)
            st.keepAwake = s.optBoolean("keepAwake", st.keepAwake)
            st.showKeyBar = s.optBoolean("showKeyBar", st.showKeyBar)
            settings = true
        }
        if (sel.keys) o.optJSONArray("keys")?.let { arr ->
            val km = KeyManager(context)
            for (i in 0 until arr.length()) {
                val k = arr.optJSONObject(i) ?: continue
                val material = runCatching { Base64.getDecoder().decode(k.getString("material")) }.getOrNull() ?: continue
                runCatching {
                    km.importSoftware(k.getString("algorithm"), material, k.optString("comment", "bsns"))
                }.onSuccess { keys++ }
            }
        }
        return Applied(hosts, known, keys, settings)
    }

    /** A trusted host-key blob must at least decode to a sane leading algorithm
     *  name (SSH `string`) — rejects truncated/garbage entries from a bad bundle. */
    private fun isPlausibleHostKey(blob: ByteArray): Boolean = runCatching {
        val algo = SshDecoder(blob).readStringUtf8()
        algo.isNotEmpty() && algo.length <= 64 && algo.all { it in ' '..'~' }
    }.getOrDefault(false)
}
