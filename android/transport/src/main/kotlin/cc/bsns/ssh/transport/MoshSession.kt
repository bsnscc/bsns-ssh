package cc.bsns.ssh.transport

import android.os.SystemClock
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
    /** Fires when an Android sleep/resume leaves mosh accepting local input but
     *  fresh remote state never returns. The holder re-bootstraps mosh. */
    var onRoamFailed: (() -> Unit)? = null
    private var staleReported = false

    private val bridge = MoshBridge()
    private var handle = 0L
    private val running = AtomicBoolean(false)
    private val lock = Any()
    private val writeQueue = ArrayList<ByteArray>()
    private var pendingResize: Pair<Int, Int>? = null
    // Current terminal size (owner-thread view) so recovery can replay it as a
    // size wiggle, forcing the server to redraw + re-home its cursor.
    private var lastCols = 0
    private var lastRows = 0
    private var lastLoopFinishedAtMs = 0L
    private var inputPushSeq = 0
    private var resumeStateNum = 0L
    private var resumeInputPushSeq = 0
    private var roamWatchActive = false
    private var roamReconnectFired = false
    private var firstInputAfterResumeAtMs = 0L
    private var readableDatagramsSinceResume = 0
    private var acceptedPacketsSinceResume = 0

    /** Open the UDP transport with the MOSH CONNECT key, then start the I/O loop.
     *  Returns false if the transport couldn't be opened. */
    fun open(cols: Int, rows: Int): Boolean {
        handle = bridge.nativeMoshOpen(ip, port.toString(), key, cols, rows)
        if (handle == 0L) return false
        lastCols = cols; lastRows = rows
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
                val loopStartedAtMs = SystemClock.elapsedRealtime()
                val loopGapMs = if (lastLoopFinishedAtMs == 0L) 0L else loopStartedAtMs - lastLoopFinishedAtMs
                val writes: List<ByteArray>
                val resize: Pair<Int, Int>?
                synchronized(lock) {
                    writes = if (writeQueue.isEmpty()) emptyList() else ArrayList(writeQueue)
                    writeQueue.clear()
                    resize = pendingResize
                    pendingResize = null
                }
                for (w in writes) {
                    inputPushSeq += 1
                    bridge.nativeMoshPush(handle, w)
                    noteRoamInput(inputPushSeq)
                }
                resize?.let { bridge.nativeMoshResize(handle, it.first, it.second); lastCols = it.first; lastRows = it.second }

                // Silence BEFORE servicing — survives a full OS suspension (where the
                // loop was frozen and never marked stale). The native repaint-on-
                // recovery uses the same elapsed-gap test; the cursor wiggle must too.
                val silenceBeforeMs = bridge.nativeMoshMsSinceContact(handle)
                if (loopGapMs > STALE_THRESHOLD_MS) armRoamWatch()
                val ansi = bridge.nativeMoshService(handle, 1000)
                if (roamWatchActive) {
                    readableDatagramsSinceResume += bridge.nativeMoshLastReadableDatagrams(handle)
                    acceptedPacketsSinceResume += bridge.nativeMoshLastAcceptedPackets(handle)
                }
                noteRoamState(bridge.nativeMoshStateNum(handle))
                if (ansi != null && ansi.isNotEmpty()) {
                    synchronized(lock) {
                        val cb = onOutput
                        if (cb != null) cb(ansi) else preBuffer.add(ansi)
                    }
                }
                // Recovered after a real gap (incl. suspension): re-home the server's
                // cursor with a size wiggle — a no-op resize won't SIGWINCH, leaving
                // the cursor / typed echo on the wrong row. (The absolute repaint half
                // is handled native-side, on the same elapsed-gap trigger.)
                if (silenceBeforeMs > STALE_THRESHOLD_MS &&
                    bridge.nativeMoshMsSinceContact(handle) < silenceBeforeMs) {
                    if (lastRows > 1) bridge.nativeMoshResize(handle, lastCols, lastRows - 1)
                    bridge.nativeMoshResize(handle, lastCols, lastRows)
                }
                checkRoamWatch()
                // nativeMoshService blocks up to ~1s, so staleness is checked
                // promptly without a separate timer.
                val stale = bridge.nativeMoshMsSinceContact(handle) > STALE_THRESHOLD_MS
                if (stale != staleReported) { staleReported = stale; onLiveness?.invoke(stale) }
                lastLoopFinishedAtMs = SystemClock.elapsedRealtime()
            }
        } finally {
            val err = if (handle != 0L) bridge.nativeMoshLastError(handle) else null
            if (handle != 0L) { bridge.nativeMoshClose(handle); handle = 0L }
            onClosed?.invoke(err)
        }
    }

    private fun armRoamWatch() {
        if (roamWatchActive) return
        resumeStateNum = bridge.nativeMoshStateNum(handle)
        resumeInputPushSeq = inputPushSeq
        roamWatchActive = true
        roamReconnectFired = false
        firstInputAfterResumeAtMs = 0L
        readableDatagramsSinceResume = 0
        acceptedPacketsSinceResume = 0
        bridge.nativeMoshHop(handle)
        bridge.nativeMoshPrimeActiveRetry(handle)
    }

    private fun clearRoamWatch() {
        roamWatchActive = false
        roamReconnectFired = false
        firstInputAfterResumeAtMs = 0L
    }

    private fun noteRoamInput(inputSeq: Int) {
        if (!roamWatchActive || firstInputAfterResumeAtMs != 0L || inputSeq <= resumeInputPushSeq) return
        firstInputAfterResumeAtMs = SystemClock.elapsedRealtime()
        bridge.nativeMoshPrimeActiveRetry(handle)
    }

    private fun noteRoamState(state: Long) {
        if (roamWatchActive && state > resumeStateNum) clearRoamWatch()
    }

    private fun checkRoamWatch() {
        if (!roamWatchActive || roamReconnectFired || firstInputAfterResumeAtMs == 0L) return
        val state = bridge.nativeMoshStateNum(handle)
        if (state > resumeStateNum) {
            clearRoamWatch()
            return
        }
        val ageMs = SystemClock.elapsedRealtime() - firstInputAfterResumeAtMs
        val noAcceptedPeer = acceptedPacketsSinceResume == 0 && ageMs >= ROAM_NO_PEER_RECONNECT_DELAY_MS
        val frozenState = acceptedPacketsSinceResume > 0 && ageMs >= ROAM_FROZEN_STATE_RECONNECT_DELAY_MS
        if (!noAcceptedPeer && !frozenState) return
        roamReconnectFired = true
        roamWatchActive = false
        onRoamFailed?.invoke()
    }

    private companion object {
        const val STALE_THRESHOLD_MS = 8000L
        // How long a resumed session may look frozen before falling back to a full
        // reconnect. Generous on purpose: mosh's own hop/prime recovery keeps retrying
        // and the terminal still accepts input meanwhile, so a reconnect (fresh
        // mosh-server, tmux re-attach) is the last resort. Too-eager thresholds abandon
        // a slow-but-recovering resume before mosh gets there.
        const val ROAM_NO_PEER_RECONNECT_DELAY_MS = 8000L
        const val ROAM_FROZEN_STATE_RECONNECT_DELAY_MS = 12000L
    }
}
