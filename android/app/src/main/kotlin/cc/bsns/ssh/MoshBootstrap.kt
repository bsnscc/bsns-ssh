package cc.bsns.ssh

/**
 * Bootstraps a mosh session the way the stock `mosh` script does: SSH in, run
 * `mosh-server`, and parse its `MOSH CONNECT <port> <key>` line — then the UDP
 * transport opens to the same host on that port with that key. Parallel to the
 * iOS `MoshBootstrap` / `MoshConnect` / `MoshServerCommand`.
 *
 * It also cleans up after itself. A mosh-server outlives its client by design
 * (that's what lets a session resume across a network change), but one whose
 * client can never return — the app was killed, or a resume failed and we
 * re-bootstrapped — keeps running and holding a PTY, and enough of those exhaust
 * the host. Nothing can revive such a server (a fresh client restarts the crypto
 * sequence at 0 and the server's replay protection rejects it), so we make them
 * reapable: every server is launched with an idle timeout, and every server we
 * abandon is asked to quit by the next connect to that host.
 */
object MoshBootstrap {
    /** `-s` binds to the SSH connection's IP; `-c 256` = 256-colour; UTF-8 locale. */
    const val SERVER_CMD_BASE = "mosh-server new -s -c 256 -l LANG=en_US.UTF-8 -l LC_ALL=en_US.UTF-8"

    /**
     * How long a server we ask to reap must have been idle before it obeys
     * SIGUSR1 — so a targeted reap can never take down a session that's actually
     * in use (including one attached from another device).
     */
    const val SIGNAL_TIMEOUT_SECONDS = 60
    const val DEFAULT_IDLE_TIMEOUT_HOURS = 24

    data class Connect(val port: Int, val key: String, val pid: Int = 0)

    /**
     * The remote command: reap the servers this device abandoned on that host,
     * then start a new one.
     *
     * `MOSH_SERVER_NETWORK_TMOUT` (seconds; 0 omits it = never expire) makes
     * mosh-server exit on its own once no client has been in touch for that
     * long. It's read from *mosh-server's own* environment, so it must be an
     * `env` prefix — mosh's `-l` flag only populates the child shell's
     * environment.
     */
    fun serverCommand(idleTimeoutSeconds: Int = DEFAULT_IDLE_TIMEOUT_HOURS * 3600,
                      reapPids: List<Int> = emptyList()): String {
        val env = buildString {
            append("env")
            if (idleTimeoutSeconds > 0) append(" MOSH_SERVER_NETWORK_TMOUT=$idleTimeoutSeconds")
            append(" MOSH_SERVER_SIGNAL_TMOUT=$SIGNAL_TIMEOUT_SECONDS")
        }
        return reapPrefix(reapPids) + env + " " + SERVER_CMD_BASE
    }

    /**
     * `for`/`case` are POSIX-shell syntax and the remote login shell might be
     * fish or csh, so the reaper is handed to `sh -c`, leaving only `sh`,
     * quoting and `;` at the top level. The `ps` check keeps a recycled PID from
     * taking an unrelated process down with it: SIGUSR1's default disposition is
     * to terminate. PIDs are integers, so the single-quoted script needs no
     * escaping. Mirrors iOS `MoshServerCommand.reapPrefix`.
     */
    fun reapPrefix(pids: List<Int>): String {
        val list = pids.filter { it > 1 }.joinToString(" ")
        if (list.isEmpty()) return ""
        return "sh -c 'for p in $list; do case \"\$(ps -p \"\$p\" -o comm= 2>/dev/null)\" in " +
            "*mosh-server*) kill -USR1 \"\$p\" 2>/dev/null ;; esac; done' ; "
    }

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
            if (port in 1..65535 && isKey(key)) return Connect(port, key, parsePid(output))
        }
        return null
    }

    /**
     * Pull the PID out of `[mosh-server detached, pid = 1234]` (printed on
     * STDERR, so the capture must include that stream). 0 = not reported; the
     * connect still succeeds, we just lose the targeted reap for that server and
     * fall back to its idle timeout.
     */
    fun parsePid(output: String?): Int {
        if (output == null) return 0
        for (raw in output.lineSequence()) {
            val line = raw.trim()
            if (!line.startsWith("[mosh-server detached")) continue
            val eq = line.indexOf('=')
            if (eq < 0) continue
            val digits = line.substring(eq + 1).substringBefore(']').trim()
            val pid = digits.toIntOrNull() ?: continue
            if (pid > 0) return pid
        }
        return 0
    }

    // 22 base64 chars (16 bytes, unpadded), the alphabet mosh emits.
    private fun isKey(s: String): Boolean =
        s.length == 22 && s.all { it.isLetterOrDigit() || it == '+' || it == '/' }
}
