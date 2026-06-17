package cc.bsns.ssh.transport

import java.util.concurrent.atomic.AtomicBoolean

/**
 * A live mosh (UDP) session — the safe Kotlin face over the mosh JNI bridge.
 * One owner thread drives the mosh transport (which isn't thread-safe): it
 * applies staged input/resizes, services the socket, and forwards the synced
 * remote framebuffer (rendered to ANSI in native) to `onOutput`.
 * `write`/`resize`/`close` are callable from any thread; they stage work and
 * poke the native wake-pipe so the owner thread services promptly. Parallel to
 * [SshSession]; bootstrap (SSH → `mosh-server`) happens before this is opened.
 */
class MoshSession(
    private val ip: String,
    private val port: Int,
    private val key: String,
) : TerminalTransport {
    private val preBuffer = ArrayList<ByteArray>()
    override var onOutput: ((ByteArray) -> Unit)? = null
        set(value) {
            synchronized(lock) {
                field = value
                if (value != null) { preBuffer.forEach(value); preBuffer.clear() }
            }
        }
    var onClosed: ((String?) -> Unit)? = null
    /** Reports liveness transitions: true when the server has gone silent past the
     *  threshold, false when contact resumes. mosh never self-closes on silence
     *  (it roams), so this is the only signal a dead session gives the UI. */
    var onLiveness: ((Boolean) -> Unit)? = null
    private var staleReported = false

    private val bridge = MoshBridge()
    private var handle = 0L
    private val running = AtomicBoolean(false)
    private val lock = Any()
    private val writeQueue = ArrayList<ByteArray>()
    private var pendingResize: Pair<Int, Int>? = null

    /** Open the UDP transport with the MOSH CONNECT key, then start the I/O loop.
     *  Returns false if the transport couldn't be opened. */
    fun open(cols: Int, rows: Int): Boolean {
        handle = bridge.nativeMoshOpen(ip, port.toString(), key, cols, rows)
        if (handle == 0L) return false
        running.set(true)
        Thread({ loop() }, "mosh-session").apply { isDaemon = true }.start()
        return true
    }

    override fun write(data: ByteArray) {
        synchronized(lock) { writeQueue.add(data) }
        if (handle != 0L) bridge.nativeMoshWake(handle)
    }

    override fun resize(cols: Int, rows: Int) {
        synchronized(lock) { pendingResize = cols to rows }
        if (handle != 0L) bridge.nativeMoshWake(handle)
    }

    override fun close() {
        running.set(false)
        if (handle != 0L) bridge.nativeMoshWake(handle)
    }

    private fun loop() {
        try {
            while (running.get()) {
                val writes: List<ByteArray>
                val resize: Pair<Int, Int>?
                synchronized(lock) {
                    writes = if (writeQueue.isEmpty()) emptyList() else ArrayList(writeQueue)
                    writeQueue.clear()
                    resize = pendingResize
                    pendingResize = null
                }
                for (w in writes) bridge.nativeMoshPush(handle, w)
                resize?.let { bridge.nativeMoshResize(handle, it.first, it.second) }

                val ansi = bridge.nativeMoshService(handle, 1000)
                if (ansi != null && ansi.isNotEmpty()) {
                    synchronized(lock) {
                        val cb = onOutput
                        if (cb != null) cb(ansi) else preBuffer.add(ansi)
                    }
                }
                // nativeMoshService blocks up to ~1s, so staleness is checked
                // promptly without a separate timer.
                val stale = bridge.nativeMoshMsSinceContact(handle) > STALE_THRESHOLD_MS
                if (stale != staleReported) { staleReported = stale; onLiveness?.invoke(stale) }
            }
        } finally {
            val err = if (handle != 0L) bridge.nativeMoshLastError(handle) else null
            if (handle != 0L) { bridge.nativeMoshClose(handle); handle = 0L }
            onClosed?.invoke(err)
        }
    }

    private companion object {
        const val STALE_THRESHOLD_MS = 8000L
    }
}
