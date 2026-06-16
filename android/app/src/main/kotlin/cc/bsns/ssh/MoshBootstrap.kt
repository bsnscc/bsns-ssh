package cc.bsns.ssh

/**
 * Bootstraps a mosh session the way the stock `mosh` script does: SSH in, run
 * `mosh-server`, and parse its `MOSH CONNECT <port> <key>` line — then the UDP
 * transport opens to the same host on that port with that key. Parallel to the
 * iOS `MoshBootstrap` / `MoshConnect`.
 */
object MoshBootstrap {
    /** `-s` binds to the SSH connection's IP; `-c 256` = 256-colour; UTF-8 locale. */
    const val SERVER_CMD = "mosh-server new -s -c 256 -l LANG=en_US.UTF-8 -l LC_ALL=en_US.UTF-8"

    data class Connect(val port: Int, val key: String)

    /**
     * Find the `MOSH CONNECT <port> <key>` line in mosh-server's output. Mirrors
     * the iOS `MoshConnect.parse` algorithm exactly so both platforms accept and
     * reject the same input: the trimmed line must START with `MOSH CONNECT ` (so
     * a `MOSH CONNECT …` substring buried mid-line never matches), the port is a
     * valid 1..65535, and the key is exactly 22 base64 chars (16-byte AES key,
     * unpadded). Trailing tokens after the key are ignored, as on iOS.
     */
    fun parse(output: String?): Connect? {
        if (output == null) return null
        for (raw in output.lineSequence()) {
            val line = raw.trim()
            if (!line.startsWith("MOSH CONNECT ")) continue
            val parts = line.split(" ").filter { it.isNotEmpty() }
            if (parts.size < 4) continue
            val port = parts[2].toIntOrNull() ?: continue
            val key = parts[3]
            if (port in 1..65535 && isKey(key)) return Connect(port, key)
        }
        return null
    }

    // 22 base64 chars (16 bytes, unpadded), the alphabet mosh emits.
    private fun isKey(s: String): Boolean =
        s.length == 22 && s.all { it.isLetterOrDigit() || it == '+' || it == '/' }
}
