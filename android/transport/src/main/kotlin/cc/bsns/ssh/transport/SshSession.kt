package cc.bsns.ssh.transport

import java.util.concurrent.atomic.AtomicBoolean

/** Why an [SshSession.open] failed — the Android analogue of the iOS
 *  SSHShellError categories, so the UI can say more than "couldn't connect".
 *  Ordinals MUST stay in sync with the OPEN_* enum in sshbridge.c. */
enum class OpenReason {
    Ok, Unreachable, Handshake, Auth, HostKeyMismatch, NoShell;

    companion object {
        fun fromCode(code: Int): OpenReason =
            entries.getOrElse(code) { Unreachable }
    }
}

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
    // Optional ProxyJump: reach `host` through this bastion (same key auths both).
    private val jumpHost: String? = null,
    private val jumpPort: Int = 22,
    private val jumpUser: String? = null,
    private val expectedBastionHostKey: ByteArray? = null,
    // When set, this is a FIDO2 security key: authenticate via the sk path using
    // this OpenSSH-format sk private key (the credential handle, not a secret) and
    // `signer.signSk`. sk keys are direct-only (no ProxyJump), so jump* are ignored.
    private val skPrivatePem: String? = null,
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

    /** Why the last [open] failed, for the UI to show a specific message. Set on
     *  a failed open; [OpenReason.Ok] otherwise. */
    var lastError: OpenReason = OpenReason.Ok
        private set

    private val bridge = SshBridge()
    private var handle = 0L
    private val running = AtomicBoolean(false)
    private val userClosed = AtomicBoolean(false)
    private val lock = Any()
    private val writeQueue = ArrayList<ByteArray>()
    private var pendingResize: Pair<Int, Int>? = null

    /** Connect + authenticate (via the Keystore signer) + open a PTY shell, then
     *  start the I/O loop. Returns false if the session couldn't be opened. */
    fun open(cols: Int, rows: Int): Boolean {
        handle = if (skPrivatePem != null) {
            bridge.nativeOpenShellSk(host, port, user, pubBlob, skPrivatePem, signer, cols, rows, expectedHostKey)
        } else {
            bridge.nativeOpenShell(host, port, user, pubBlob, signer, cols, rows, expectedHostKey,
                jumpHost, jumpPort, jumpUser, expectedBastionHostKey)
        }
        if (handle == 0L) {
            lastError = OpenReason.fromCode(bridge.nativeLastOpenReason())
            return false
        }
        lastError = OpenReason.Ok
        running.set(true)
        Thread({ loop() }, "ssh-session").apply { isDaemon = true }.start()
        return true
    }

    override fun write(data: ByteArray) {
        synchronized(lock) { writeQueue.add(data) }
        bridge.nativeWake(handle)   // interrupt the idle wait so input goes out now
    }

    override fun resize(cols: Int, rows: Int) {
        synchronized(lock) { pendingResize = cols to rows }
        bridge.nativeWake(handle)
    }

    override fun close() {
        userClosed.set(true)
        running.set(false)
        bridge.nativeWake(handle)   // wake the loop so it exits promptly
    }

    // Bytes staged for the channel that haven't gone out yet (owner-thread only).
    // libssh2_channel_write can take only part of a buffer under backpressure, so
    // we keep the unsent tail here and retry rather than spin or drop it.
    private var outBuf = ByteArray(0)

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
            // Append newly-staged input to whatever didn't fit last time, then push
            // as much as the channel will take in one pass; keep the remainder for
            // the next turn (nativeWait below parks on OUTBOUND until it's writable).
            if (writes.isNotEmpty()) outBuf = writes.fold(outBuf) { acc, w -> acc + w }
            if (outBuf.isNotEmpty()) {
                val wrote = bridge.nativeWrite(handle, outBuf)
                if (wrote < 0) { running.set(false); break }
                if (wrote > 0) outBuf = if (wrote >= outBuf.size) ByteArray(0) else outBuf.copyOfRange(wrote, outBuf.size)
            }
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
                // No data right now: park on the session fd + wake-pipe instead of
                // busy-polling at 100Hz. A typed byte / resize / close pokes the
                // wake-pipe (nativeWake) so it returns immediately; the 1s cap keeps
                // keepalives ticking even on a fully idle session.
                else -> bridge.nativeWait(handle, 1000)
            }
        }
        bridge.nativeClose(handle)
        // A non-null reason means the peer dropped us (vs. a user-initiated close),
        // so the UI can offer to reconnect.
        onClosed?.invoke(if (userClosed.get()) null else "connection dropped")
    }
}
