package cc.bsns.ssh.transport

import java.util.concurrent.atomic.AtomicBoolean

/** One local (-L) forward: listen on `localhost:listenPort`, tunnel to `dest`. */
class Forward(val listenPort: Int, val destHost: String, val destPort: Int, val error: String? = null)

/**
 * A dedicated SSH connection that hosts several local port forwards. One owner
 * thread services accept + pump (libssh2 isn't thread-safe); `addForward` /
 * `removeForward` are callable from any thread (they only bind/mark sockets).
 * Parallel to [SshSession] but standalone — it isn't a terminal transport.
 */
class ForwardSession(
    private val host: String,
    private val port: Int,
    private val user: String,
    private val pubBlob: ByteArray,
    private val signer: Any,
    private val expectedHostKey: ByteArray? = null,
) {
    private val bridge = SshBridge()
    private var handle = 0L
    private val running = AtomicBoolean(false)
    private val lock = Any()
    private val forwards = ArrayList<Forward>()
    var onClosed: (() -> Unit)? = null

    fun open(): Boolean {
        handle = bridge.nativeForwardOpen(host, port, user, pubBlob, signer, expectedHostKey)
        if (handle == 0L) return false
        running.set(true)
        Thread({ loop() }, "ssh-forwards").apply { isDaemon = true }.start()
        return true
    }

    /** Returns null on success, or a human-readable reason on failure. */
    fun addForward(listenPort: Int, destHost: String, destPort: Int): String? {
        if (handle == 0L) return "not connected"
        return when (val rc = bridge.nativeForwardAdd(handle, listenPort, destHost, destPort)) {
            0 -> { synchronized(lock) { forwards.add(Forward(listenPort, destHost, destPort)) }; null }
            98 -> "port $listenPort is already in use"
            13 -> "port $listenPort needs elevated privileges"
            else -> "couldn't bind port $listenPort (error $rc)"
        }
    }

    fun removeForward(listenPort: Int) {
        if (handle != 0L) bridge.nativeForwardRemove(handle, listenPort)
        synchronized(lock) { forwards.removeAll { it.listenPort == listenPort } }
    }

    fun list(): List<Forward> = synchronized(lock) { ArrayList(forwards) }

    fun close() { running.set(false) }

    private fun loop() {
        try {
            while (running.get()) {
                if (bridge.nativeForwardService(handle, 300) < 0) break   // session died
            }
        } finally {
            if (handle != 0L) { bridge.nativeForwardClose(handle); handle = 0L }
            onClosed?.invoke()
        }
    }
}
