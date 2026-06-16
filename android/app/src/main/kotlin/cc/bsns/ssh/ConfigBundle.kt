package cc.bsns.ssh

import android.content.Context
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

    /** Merge a parsed bundle into the local stores (additive; dups skipped). */
    fun apply(context: Context, o: JSONObject) {
        val hostStore = HostStore(context)
        o.optJSONArray("hosts")?.let { arr ->
            for (i in 0 until arr.length()) {
                val h = arr.getJSONObject(i)
                hostStore.add(SavedHost(h.getString("host"), h.getInt("port"), h.getString("user")))
            }
        }
        o.optJSONObject("knownHosts")?.let { kh ->
            kh.keys().forEach { id -> kh.getString(id).let { KnownHostsStore(context).trustRaw(id, Base64.getDecoder().decode(it)) } }
        }
        o.optJSONObject("settings")?.let { s ->
            val st = SettingsStore(context)
            st.fontSize = s.optInt("fontSize", st.fontSize).coerceIn(8, 30)
            st.scrollback = s.optInt("scrollback", st.scrollback)
            st.cursorBlink = s.optBoolean("cursorBlink", st.cursorBlink)
            st.keepAwake = s.optBoolean("keepAwake", st.keepAwake)
            st.showKeyBar = s.optBoolean("showKeyBar", st.showKeyBar)
        }
        o.optJSONArray("keys")?.let { arr ->
            val km = KeyManager(context)
            for (i in 0 until arr.length()) {
                val k = arr.getJSONObject(i)
                km.importSoftware(k.getString("algorithm"),
                    Base64.getDecoder().decode(k.getString("material")), k.optString("comment", "bsns"))
            }
        }
    }
}
