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

    // The mosh key is 16 bytes, unpadded base64 = EXACTLY 22 chars (matches the
    // iOS MoshConnect rule). A `$` anchor + no trailing base64 char rejects an
    // overlong key rather than truncating it.
    private val LINE = Regex("""MOSH CONNECT (\d{1,5}) ([A-Za-z0-9/+]{22})$""")

    /** Find the `MOSH CONNECT <port> <key>` line in mosh-server's output. */
    fun parse(output: String?): Connect? {
        if (output == null) return null
        for (raw in output.lineSequence()) {
            val m = LINE.find(raw.trim()) ?: continue
            val port = m.groupValues[1].toIntOrNull() ?: continue
            if (port in 1..65535) return Connect(port, m.groupValues[2])
        }
        return null
    }
}
