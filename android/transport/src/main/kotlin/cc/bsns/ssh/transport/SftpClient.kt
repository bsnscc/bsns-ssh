package cc.bsns.ssh.transport

import java.util.concurrent.Callable
import java.util.concurrent.Executors

/** One directory entry from an SFTP listing. `permissions` is the low 12 mode
 *  bits (0 if the server didn't report them). */
class SftpEntry(val name: String, val isDirectory: Boolean, val size: Long, val permissions: Int = 0)

/**
 * A persistent SFTP session over its own authenticated libssh2 connection.
 * libssh2 sessions aren't thread-safe, so every native call is serialised onto
 * one private thread; the public API is blocking and meant to be called off the
 * main thread. Auth delegates to the same Keystore/FileKey signer as the shell,
 * so a private key never touches the transport. Mirrors the iOS `SFTPClient`.
 */
class SftpClient(
    private val host: String,
    private val port: Int,
    private val user: String,
    private val pubBlob: ByteArray,
    private val signer: Any,
    private val expectedHostKey: ByteArray? = null,
) {
    private val exec = Executors.newSingleThreadExecutor()
    private val bridge = SshBridge()
    @Volatile private var handle = 0L

    private fun <T> on(body: () -> T): T = exec.submit(Callable { body() }).get()

    fun connect(): Boolean = on {
        handle = bridge.nativeSftpOpen(host, port, user, pubBlob, signer, expectedHostKey)
        handle != 0L
    }

    fun list(path: String): List<SftpEntry> = on {
        // A null result means the directory couldn't be opened (permission denied,
        // gone, not a directory, or a dropped connection) — surface it as an error
        // rather than an empty folder. A genuinely empty directory returns an
        // (empty but non-null) array.
        val rows = bridge.nativeSftpList(handle, path)
            ?: throw java.io.IOException("couldn't open directory: $path")
        rows.mapNotNull { row ->
            val p = row.split('\t', limit = 4)
            if (p.size < 4) null
            else SftpEntry(p[3], p[0] == "d", p[1].toLongOrNull() ?: 0L, p[2].toIntOrNull(8) ?: 0)
        }.sortedWith(compareByDescending<SftpEntry> { it.isDirectory }.thenBy { it.name.lowercase() })
    }

    /** Stream a remote file into `out` in fixed-size chunks (bounded memory,
     *  no whole-file buffering). Runs entirely on the session's owner thread. */
    fun downloadTo(path: String, out: java.io.OutputStream): Boolean = on {
        val fh = bridge.nativeSftpOpenRead(handle, path)
        if (fh == 0L) return@on false
        try {
            val buf = ByteArray(32768)
            while (true) {
                val n = bridge.nativeSftpReadChunk(fh, buf)
                if (n > 0) out.write(buf, 0, n)
                else if (n == 0) break
                else return@on false        // read error
            }
            out.flush(); true
        } finally { bridge.nativeSftpCloseFile(fh) }
    }

    /** Stream `input` to a remote file in fixed-size chunks (bounded memory).
     *  Transactional: the bytes go to a temp sibling path and are renamed onto
     *  `path` only after the whole stream lands, so a mid-transfer failure never
     *  leaves a partial file under the intended name. The temp is removed on any
     *  failure. Still streaming — no whole-file buffering. */
    fun uploadFrom(path: String, input: java.io.InputStream): Boolean = on {
        // <dest>.<rand>.tmp sits in the same directory, so the final rename is a
        // cheap same-filesystem move (and inherits the dest's permissions context).
        val tmp = "$path.${java.util.UUID.randomUUID().toString().take(8)}.tmp"
        val fh = bridge.nativeSftpOpenWrite(handle, tmp)
        if (fh == 0L) return@on false
        var wrote = false
        try {
            val buf = ByteArray(32768)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                if (n > 0 && !bridge.nativeSftpWriteChunk(fh, buf, n)) return@on false
            }
            wrote = true
        } finally {
            bridge.nativeSftpCloseFile(fh)
            // Drop the temp if we never reached a clean end-of-stream (or the rename
            // below fails) so a failed upload doesn't leave a stray .tmp behind.
            if (!wrote) bridge.nativeSftpRemove(handle, tmp, false)
        }
        // Atomically swap the completed temp onto the final path; clean up on failure.
        if (!bridge.nativeSftpRename(handle, tmp, path)) {
            bridge.nativeSftpRemove(handle, tmp, false)
            return@on false
        }
        true
    }

    fun mkdir(path: String): Boolean = on { bridge.nativeSftpMkdir(handle, path) }
    fun remove(path: String, isDir: Boolean): Boolean = on { bridge.nativeSftpRemove(handle, path, isDir) }

    /** Rename or move `from` to `to` (both full server paths). */
    fun rename(from: String, to: String): Boolean = on { bridge.nativeSftpRename(handle, from, to) }

    /** chmod `path` to `mode` (low 12 permission bits, e.g. 0o644). */
    fun setPermissions(path: String, mode: Int): Boolean = on { bridge.nativeSftpSetPermissions(handle, path, mode) }

    fun close() {
        try { on { if (handle != 0L) bridge.nativeSftpClose(handle); handle = 0L } } catch (_: Exception) {}
        exec.shutdown()
    }
}
