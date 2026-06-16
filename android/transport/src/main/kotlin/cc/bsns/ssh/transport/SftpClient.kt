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

    fun download(path: String): ByteArray? = on { bridge.nativeSftpRead(handle, path) }
    fun upload(path: String, data: ByteArray): Boolean = on { bridge.nativeSftpWrite(handle, path, data) }
    fun mkdir(path: String): Boolean = on { bridge.nativeSftpMkdir(handle, path) }
    fun remove(path: String, isDir: Boolean): Boolean = on { bridge.nativeSftpRemove(handle, path, isDir) }

    fun close() {
        try { on { if (handle != 0L) bridge.nativeSftpClose(handle); handle = 0L } } catch (_: Exception) {}
        exec.shutdown()
    }
}
