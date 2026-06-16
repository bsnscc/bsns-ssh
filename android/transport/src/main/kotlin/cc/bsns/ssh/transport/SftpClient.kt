package cc.bsns.ssh.transport

import java.util.concurrent.Callable
import java.util.concurrent.Executors

/** One directory entry from an SFTP listing. */
class SftpEntry(val name: String, val isDirectory: Boolean, val size: Long)

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
        val rows = bridge.nativeSftpList(handle, path) ?: return@on emptyList()
        rows.mapNotNull { row ->
            val p = row.split('\t', limit = 3)
            if (p.size < 3) null
            else SftpEntry(p[2], p[0] == "d", p[1].toLongOrNull() ?: 0L)
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

    /** Stream `input` to a remote file in fixed-size chunks (bounded memory). */
    fun uploadFrom(path: String, input: java.io.InputStream): Boolean = on {
        val fh = bridge.nativeSftpOpenWrite(handle, path)
        if (fh == 0L) return@on false
        try {
            val buf = ByteArray(32768)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                if (n > 0 && !bridge.nativeSftpWriteChunk(fh, buf, n)) return@on false
            }
            true
        } finally { bridge.nativeSftpCloseFile(fh) }
    }

    fun mkdir(path: String): Boolean = on { bridge.nativeSftpMkdir(handle, path) }
    fun remove(path: String, isDir: Boolean): Boolean = on { bridge.nativeSftpRemove(handle, path, isDir) }

    fun close() {
        try { on { if (handle != 0L) bridge.nativeSftpClose(handle); handle = 0L } } catch (_: Exception) {}
        exec.shutdown()
    }
}
