package cc.bsns.ssh.transport

import java.util.concurrent.atomic.AtomicBoolean

/**
 * A live interactive SSH session — the safe Kotlin face over the raw JNI bridge.
 * One owner thread drives the libssh2 session (which isn't thread-safe): it
 * drains staged writes/resizes and reads output, pushing it to `onOutput`.
 * `write`/`resize`/`close` are callable from any thread; they only stage work.
 * This mirrors the iOS `SSHShell` model.
 */
class SshSession(
    private val host: String,
    private val port: Int,
    private val user: String,
    private val pubBlob: ByteArray,
    private val signer: Any,
    private val expectedHostKey: ByteArray? = null,
) : TerminalTransport {
    // Output that arrives before a consumer attaches `onOutput` is buffered and
    // flushed when it's set, so the initial banner/prompt is never dropped (the
    // loop starts at open(), which may be before the UI wires up).
    private val preBuffer = ArrayList<ByteArray>()
    override var onOutput: ((ByteArray) -> Unit)? = null
        set(value) {
            synchronized(lock) {
                field = value
                if (value != null) { preBuffer.forEach(value); preBuffer.clear() }
            }
        }
    var onClosed: ((String?) -> Unit)? = null

    private val bridge = SshBridge()
    private var handle = 0L
    private val running = AtomicBoolean(false)
    private val lock = Any()
    private val writeQueue = ArrayList<ByteArray>()
    private var pendingResize: Pair<Int, Int>? = null

    /** Connect + authenticate (via the Keystore signer) + open a PTY shell, then
     *  start the I/O loop. Returns false if the session couldn't be opened. */
    fun open(cols: Int, rows: Int): Boolean {
        handle = bridge.nativeOpenShell(host, port, user, pubBlob, signer, cols, rows, expectedHostKey)
        if (handle == 0L) return false
        running.set(true)
        Thread({ loop() }, "ssh-session").apply { isDaemon = true }.start()
        return true
    }

    override fun write(data: ByteArray) {
        synchronized(lock) { writeQueue.add(data) }
    }

    override fun resize(cols: Int, rows: Int) {
        synchronized(lock) { pendingResize = cols to rows }
    }

    override fun close() {
        running.set(false)
    }

    private fun loop() {
        val buf = ByteArray(16384)
        while (running.get()) {
            val writes: List<ByteArray>
            val resize: Pair<Int, Int>?
            synchronized(lock) {
                writes = if (writeQueue.isEmpty()) emptyList() else ArrayList(writeQueue)
                writeQueue.clear()
                resize = pendingResize
                pendingResize = null
            }
            for (w in writes) bridge.nativeWrite(handle, w)
            resize?.let { bridge.nativeResize(handle, it.first, it.second) }

            when (val n = bridge.nativeRead(handle, buf)) {
                in 1..Int.MAX_VALUE -> {
                    val chunk = buf.copyOf(n)
                    synchronized(lock) {
                        val cb = onOutput
                        if (cb != null) cb(chunk) else preBuffer.add(chunk)
                    }
                }
                -1 -> { running.set(false) }
                else -> Thread.sleep(10)   // no data right now
            }
        }
        bridge.nativeClose(handle)
        onClosed?.invoke(null)
    }
}
