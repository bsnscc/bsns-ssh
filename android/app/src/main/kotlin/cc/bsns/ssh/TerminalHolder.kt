package cc.bsns.ssh

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Typeface
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import cc.bsns.ssh.transport.MoshSession
import cc.bsns.ssh.transport.SshSession
import cc.bsns.ssh.transport.TerminalTransport
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import kotlin.concurrent.thread
import kotlin.math.abs

enum class ConnStatus { Connected, Reconnecting, Disconnected }

/**
 * Holds one session's TerminalView + emulator outside composition so the buffer
 * survives tab switches. On a dropped connection it exposes [status] = Disconnected
 * and [reconnect] rebuilds the transport behind the same terminal (iOS reconnect
 * parity). Also applies the colour theme / cursor shape / bell at session start.
 */
/** Output-side cues (lowercased) that a secret is being prompted for, used to keep
 *  typed passwords out of command history. See [TerminalHolder.noteOutputForSecretPrompt]. */
private val SECRET_PROMPT_CUES = listOf(
    "password:", "password for", "'s password", "passphrase",
    "[sudo] password", "verification code", "one-time password",
    "enter pin", "pin:", "otp",
)
private val ESC_BYTES = byteArrayOf(0x1B.toByte())
private val TMUX_COPY_MODE_BYTES = byteArrayOf(0x02.toByte(), 0x5B.toByte())
private val SCREEN_COPY_MODE_BYTES = byteArrayOf(0x01.toByte(), 0x5B.toByte())
private val REMOTE_UP_BYTES = "\u001B[A".toByteArray(Charsets.UTF_8)
private val REMOTE_DOWN_BYTES = "\u001B[B".toByteArray(Charsets.UTF_8)

private object KeySequence {
    fun bytes(spec: String, fallback: ByteArray): ByteArray {
        val out = ArrayList<Byte>()
        spec.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.forEach { token ->
            out.addAll(parseToken(token).toList())
        }
        return if (out.isEmpty()) fallback else out.toByteArray()
    }

    private fun parseToken(token: String): ByteArray {
        val lower = token.lowercase()
        when (lower) {
            "esc", "escape" -> return byteArrayOf(0x1B)
            "tab" -> return byteArrayOf(0x09)
            "enter", "return" -> return byteArrayOf(0x0D)
            "space" -> return byteArrayOf(0x20)
        }
        if (lower.startsWith("0x")) {
            lower.drop(2).toIntOrNull(16)?.takeIf { it in 0..255 }?.let {
                return byteArrayOf(it.toByte())
            }
        }
        controlCharacter(token)?.let { return byteArrayOf(it) }
        return token.toByteArray(Charsets.UTF_8)
    }

    private fun controlCharacter(token: String): Byte? {
        val lower = token.lowercase()
        val ch = when {
            lower.startsWith("ctrl-") -> token.drop(5).firstOrNull()
            lower.startsWith("control-") -> token.drop(8).firstOrNull()
            lower.startsWith("c-") -> token.drop(2).firstOrNull()
            lower.startsWith("^") -> token.drop(1).firstOrNull()
            else -> null
        } ?: return null
        return (ch.uppercaseChar().code and 0x1F).toByte()
    }
}

class TerminalHolder(
    context: android.content.Context,
    initialSession: TerminalTransport,
    val title: String,
    private val reconnectFactory: () -> TerminalTransport?,
    fontSizeSp: Int = 14,
    scrollback: Int = 5000,
    keepAwake: Boolean = true,
    cursorBlink: Boolean = true,
    theme: TerminalTheme = Appearance.themes[0],
    cursorStyle: String = "block",
    bellHaptic: Boolean = false,
) {
    var session: TerminalTransport = initialSession
        private set
    var status by mutableStateOf(ConnStatus.Connected)
    /** mosh-only: server silent past the liveness threshold. status stays
     *  Connected (mosh may roam back), but the UI shows staleness so a dead
     *  session isn't a reassuring green. */
    var isStale by mutableStateOf(false)
        private set
    var remoteScrollActive by mutableStateOf(false)
        private set
    /** Why the session is in [ConnStatus.Disconnected] — shown in the banner so a
     *  drop isn't just a bare "Disconnected". Null for a plain peer drop. */
    var disconnectReason by mutableStateOf<String?>(null)
        private set
    private var userClosing = false

    // Local command history + the line currently being typed (for suggestions).
    private val history = CommandHistory(context)
    private val settingsStore = SettingsStore(context)
    var currentLine by mutableStateOf("")
        private set
    private val lineBuf = StringBuilder()
    private var inEscape = false
    // Armed when recent OUTPUT looks like a password/passphrase prompt — the next
    // submitted line is then NOT recorded. At such a prompt the remote reads with
    // echo OFF, but the keystrokes still flow through trackInput, so without this
    // a typed password would land in history. Touched from the output thread
    // (noteOutputForSecretPrompt) and the write thread (trackInput).
    @Volatile private var awaitingSecret = false
    private val outTail = StringBuilder()
    private var remoteScrollLastY = 0f
    private var remoteScrollRemainder = 0f

    /** Inspect transport output and arm secret-suppression on a password prompt.
     *  Liberal on purpose: a false positive only drops one history entry, while a
     *  miss would record a password — so bias hard toward suppression. */
    private fun noteOutputForSecretPrompt(bytes: ByteArray) {
        synchronized(outTail) {
            for (b in bytes) {
                val c = b.toInt() and 0xFF
                if (c in 0x20..0x7e || c == 0x0a) outTail.append(c.toChar())
            }
            if (outTail.length > 256) outTail.delete(0, outTail.length - 256)
            val hay = outTail.toString().lowercase()
            if (SECRET_PROMPT_CUES.any { hay.contains(it) }) {
                awaitingSecret = true
                outTail.setLength(0)
            }
        }
    }

    fun suggestionsFor(prefix: String): List<String> = history.suggestions(prefix)
    fun history(): List<String> = history.all()
    fun clearHistory() = history.clear()

    fun enterTmuxScrollMode() {
        if (status != ConnStatus.Connected) return
        session.write(KeySequence.bytes(settingsStore.tmuxScrollSequence, TMUX_COPY_MODE_BYTES))
        setRemoteScrollMode(true)
    }

    fun enterScreenScrollMode() {
        if (status != ConnStatus.Connected) return
        session.write(KeySequence.bytes(settingsStore.screenScrollSequence, SCREEN_COPY_MODE_BYTES))
        setRemoteScrollMode(true)
    }

    fun enterTmuxScrollModeFromAlternateScroll(event: MotionEvent?, rowsDown: Int): Boolean {
        if (status != ConnStatus.Connected || remoteScrollActive || rowsDown >= 0) return false
        session.write(KeySequence.bytes(settingsStore.tmuxScrollSequence, TMUX_COPY_MODE_BYTES))
        setRemoteScrollMode(true)
        if (event != null) remoteScrollLastY = event.y
        sendRemoteScrollRows(-rowsDown)
        return true
    }

    fun finishRemoteScrollMode(sendEscape: Boolean = true) {
        setRemoteScrollMode(false)
        if (sendEscape && status == ConnStatus.Connected) session.write(ESC_BYTES)
    }

    @SuppressLint("ClickableViewAccessibility")
    fun setRemoteScrollMode(active: Boolean) {
        if (remoteScrollActive == active) return
        remoteScrollActive = active
        remoteScrollRemainder = 0f
        if (active) {
            terminalView.requestFocus()
            terminalView.setOnTouchListener(View.OnTouchListener { _, event ->
                handleRemoteScrollTouch(event)
            })
        } else {
            terminalView.setOnTouchListener(null)
        }
    }

    private fun handleRemoteScrollTouch(event: MotionEvent): Boolean {
        if (!remoteScrollActive) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                remoteScrollLastY = event.y
                remoteScrollRemainder = 0f
            }
            MotionEvent.ACTION_MOVE -> {
                val deltaY = event.y - remoteScrollLastY
                remoteScrollLastY = event.y
                remoteScrollRemainder += deltaY
                sendRemoteScrollSteps()
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                remoteScrollRemainder = 0f
            }
        }
        return true
    }

    private fun sendRemoteScrollSteps() {
        val rows = terminalView.mEmulator?.mRows?.coerceAtLeast(1) ?: 24
        val lineHeight = (terminalView.height / rows.toFloat()).coerceAtLeast(12f)
        var steps = (remoteScrollRemainder / lineHeight).toInt().coerceIn(-30, 30)
        if (steps == 0) return
        remoteScrollRemainder -= steps * lineHeight
        sendRemoteScrollRows(steps)
    }

    private fun sendRemoteScrollRows(rowsDown: Int, clamp: Boolean = true) {
        val rows = if (clamp) rowsDown.coerceIn(-30, 30) else rowsDown
        if (rows == 0) return
        val bytes = if (rows > 0) REMOTE_UP_BYTES else REMOTE_DOWN_BYTES
        repeat(abs(rows)) { session.write(bytes) }
    }

    fun sendRemoteScrollPage(up: Boolean) {
        if (status != ConnStatus.Connected) return
        val rows = ((terminalView.mEmulator?.mRows ?: 24) - 2).coerceAtLeast(1)
        sendRemoteScrollRows(if (up) rows else -rows, clamp = false)
    }

    private fun handleRemoteScrollHardwareKey(keyCode: Int, event: KeyEvent): Boolean {
        if (!remoteScrollActive || event.action != KeyEvent.ACTION_DOWN) return false
        val modified = event.isShiftPressed || event.isCtrlPressed || event.isAltPressed || event.isMetaPressed
        if (modified) return false
        return when (keyCode) {
            KeyEvent.KEYCODE_PAGE_UP -> {
                sendRemoteScrollPage(up = true)
                true
            }
            KeyEvent.KEYCODE_PAGE_DOWN -> {
                sendRemoteScrollPage(up = false)
                true
            }
            KeyEvent.KEYCODE_ESCAPE -> {
                finishRemoteScrollMode(sendEscape = true)
                true
            }
            else -> false
        }
    }

    /** Send the completion's remaining suffix to the shell (the prefix is already typed). */
    fun applyCompletion(full: String) {
        val typed = currentLine
        if (full.length > typed.length && full.startsWith(typed)) {
            session.write(full.substring(typed.length).toByteArray(Charsets.UTF_8))
        }
    }

    // Track typed input by watching the byte stream to the shell: accumulate a
    // line buffer and record it on Enter. Best-effort (ignores escape sequences);
    // it feeds local suggestions only, never leaves the device.
    private fun trackInput(bytes: ByteArray) {
        for (b in bytes) {
            val c = b.toInt() and 0xFF
            when {
                inEscape -> if (c in 0x40..0x7e) inEscape = false   // end of an escape seq
                c == 0x1b -> inEscape = true
                c == 0x0d || c == 0x0a -> {                          // Enter — commit the line
                    val raw = lineBuf.toString()
                    val line = raw.trim()
                    // A line submitted right after a password prompt is a secret — never
                    // record it (disarm; a wrong-password retry re-arms on the next prompt).
                    val secret = awaitingSecret
                    awaitingSecret = false
                    // ignorespace convention + history toggle: a leading-space line is
                    // never recorded (use it for secrets), and history can be disabled.
                    if (!secret && line.isNotEmpty() && !raw.startsWith(" ") && settingsStore.commandHistory) {
                        history.record(line)
                    }
                    lineBuf.setLength(0)
                }
                c == 0x03 || c == 0x15 -> lineBuf.setLength(0)       // Ctrl-C / Ctrl-U
                c == 0x7f || c == 0x08 -> if (lineBuf.isNotEmpty()) lineBuf.setLength(lineBuf.length - 1)
                c in 0x20..0x7e -> lineBuf.append(c.toChar())
            }
        }
        main.post { currentLine = lineBuf.toString() }
    }

    // The live font size; pinch-to-zoom changes it (see [onPinch]).
    private var currentFontSp = fontSizeSp

    val terminalView = TerminalView(context, null).apply {
        setTextSize((fontSizeSp * resources.displayMetrics.scaledDensity).toInt())
        setTypeface(Typeface.MONOSPACE)
        keepScreenOn = keepAwake
        isFocusableInTouchMode = true
    }
    private val vibrator =
        if (bellHaptic) context.getSystemService(android.content.Context.VIBRATOR_SERVICE) as? android.os.Vibrator else null
    private val termSession: TerminalSession

    init {
        val io = object : TerminalSession.ExternalIo {
            override fun write(data: ByteArray, offset: Int, count: Int) {
                val bytes = data.copyOfRange(offset, offset + count)
                trackInput(bytes)
                session.write(bytes)
            }
            override fun onResize(columns: Int, rows: Int) = session.resize(columns, rows)
        }
        termSession = TerminalSession(scrollback,
            BsnsSessionClient(
                { terminalView.onScreenUpdated() },
                { vibrate() },
                readClipboard = {
                    val cm = terminalView.context
                        .getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                    cm?.primaryClip?.getItemAt(0)
                        ?.coerceToText(terminalView.context)?.toString()
                },
                writeClipboard = { text ->
                    val cm = terminalView.context
                        .getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                    cm?.setPrimaryClip(ClipData.newPlainText("bsns.SSH", text))
                },
            ), io)
        terminalView.setTerminalViewClient(BsnsViewClient(
            view = { terminalView },
            onEmulatorReady = {
                wireOutput(initialSession)
                terminalView.mEmulator?.let { Appearance.apply(it, theme) }
                val esc = Appearance.cursorStyleEscape(cursorStyle)
                termSession.appendToEmulator(esc, esc.size)
                if (cursorBlink) {
                    terminalView.setTerminalCursorBlinkerRate(500)
                    terminalView.setTerminalCursorBlinkerState(true, true)
                }
                terminalView.invalidate()
            },
            onAlternateBufferScroll = { event, rowsDown ->
                enterTmuxScrollModeFromAlternateScroll(event, rowsDown)
            },
            onScale = { onPinch(it) },
        ))
        terminalView.setOnKeyListener { _, keyCode, event ->
            handleRemoteScrollHardwareKey(keyCode, event)
        }
        terminalView.attachSession(termSession)
    }

    /** Pinch-to-zoom (iOS parity). The view accumulates the gesture's scale; once
     *  it passes ±10% we step the font by 1sp — clamped to the Settings range — and
     *  reset the accumulator. The new size also becomes the default for new sessions. */
    private fun onPinch(scale: Float): Float {
        if (scale in 0.9f..1.1f) return scale
        zoom(if (scale > 1f) 1 else -1)
        return 1f
    }

    /** Step the font size by [delta] sp (pinch, or the keyboard zoom shortcuts),
     *  clamped to the Settings range; the result becomes the new default. */
    fun zoom(delta: Int) {
        val next = (currentFontSp + delta).coerceIn(MIN_FONT_SP, MAX_FONT_SP)
        if (next == currentFontSp) return
        currentFontSp = next
        terminalView.setTextSize((next * terminalView.resources.displayMetrics.scaledDensity).toInt())
        settingsStore.fontSize = next
    }

    private fun vibrate() {
        vibrator?.vibrate(android.os.VibrationEffect.createOneShot(30, android.os.VibrationEffect.DEFAULT_AMPLITUDE))
    }

    /** Send a snippet's command(s) to the session, with a trailing newline so the
     *  last line executes. Multi-line snippets run as a sequence. */
    fun runSnippet(command: String) {
        if (status != ConnStatus.Connected) return
        val text = if (command.endsWith("\n")) command else command + "\n"
        session.write(text.toByteArray(Charsets.UTF_8))
    }

    // Coalesce incoming output: many small network chunks accumulate into one
    // buffer and a single main-thread drain feeds the emulator once per frame,
    // instead of one post()+redraw per packet (iOS coalesces the same way via
    // TerminalSurface.scheduleFlush). Bytes are appended in arrival order and
    // never dropped — the buffer just batches them.
    private val outBuf = java.io.ByteArrayOutputStream()
    private var drainScheduled = false

    private fun wireOutput(s: TerminalTransport) {
        s.onOutput = { bytes ->
            noteOutputForSecretPrompt(bytes)
            val post: Boolean
            synchronized(outBuf) {
                outBuf.write(bytes)
                post = !drainScheduled
                if (post) drainScheduled = true
            }
            if (post) main.post {
                val batch: ByteArray
                synchronized(outBuf) {
                    batch = outBuf.toByteArray()
                    outBuf.reset()
                    drainScheduled = false
                }
                if (batch.isNotEmpty()) termSession.appendToEmulator(batch, batch.size)
            }
        }
        when (s) {
            is SshSession -> s.onClosed = { reason -> onDropped(reason) }
            is MoshSession -> {
                s.onClosed = { reason -> onDropped(reason) }
                s.onLiveness = { stale -> main.post { isStale = stale } }
                s.onRoamFailed = { main.post { handleMoshRoamFailed() } }
            }
        }
    }

    private fun onDropped(reason: String?) {
        if (!userClosing) main.post {
            if (status == ConnStatus.Connected) {
                disconnectReason = reason
                status = ConnStatus.Disconnected
            }
        }
    }

    private fun handleMoshRoamFailed() {
        if (status != ConnStatus.Connected) return
        reconnect()
    }

    /** Rebuild the transport behind the same terminal view (the buffer persists). */
    fun reconnect() {
        if (status == ConnStatus.Reconnecting) return
        status = ConnStatus.Reconnecting
        isStale = false
        val old = session   // the stale/dropped transport we're replacing
        thread {
            val s = reconnectFactory()
            main.post {
                if (s != null) {
                    // Detach + close the old transport so its thread/socket can't keep
                    // feeding output / closed / liveness callbacks into this holder
                    // (which would duplicate output and flip status after replacement).
                    old.onOutput = null
                    when (old) {
                        is MoshSession -> { old.onClosed = null; old.onLiveness = null; old.onRoamFailed = null }
                        is SshSession -> old.onClosed = null
                    }
                    old.close()
                    session = s
                    wireOutput(s)
                    terminalView.mEmulator?.let { s.resize(it.mColumns, it.mRows) }
                    disconnectReason = null
                    status = ConnStatus.Connected
                } else {
                    // The factory swallows the per-category reason on a failed open;
                    // surface an honest "couldn't reconnect" rather than a bare dot.
                    disconnectReason = "Couldn't reconnect — the server may still be unreachable."
                    status = ConnStatus.Disconnected
                }
            }
        }
    }

    fun close() {
        userClosing = true
        session.onOutput = null
        (session as? MoshSession)?.let {
            it.onClosed = null
            it.onLiveness = null
            it.onRoamFailed = null
        }
        session.close()
    }
}
