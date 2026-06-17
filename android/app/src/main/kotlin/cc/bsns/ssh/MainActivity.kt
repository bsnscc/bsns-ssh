package cc.bsns.ssh

import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.compose.setContent
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.fragment.app.FragmentActivity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Divider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import cc.bsns.ssh.core.SshKeyFormat
import cc.bsns.ssh.transport.MoshSession
import cc.bsns.ssh.transport.SshBridge
import cc.bsns.ssh.transport.SshSession
import cc.bsns.ssh.transport.TerminalTransport
import kotlin.concurrent.thread

class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        YubiKeyManager.attach(this)   // for NFC reader-mode + USB discovery
        // Set the secure flag up front so the very first recents snapshot is
        // protected — don't wait for a resume round-trip (a privacy guarantee).
        applySecureFlag(window, SettingsStore(this).appLock)
        // Brand-tinted dark scheme: the icon's #00C29C accent on the #0F0F0F near-black,
        // so buttons, switches, and selected states match the icon + the iOS app.
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(
                primary = Brand.accent,
                secondary = Brand.accent,
                tertiary = Brand.accent,
                background = Brand.nearBlack,
                surface = Brand.nearBlack,
                surfaceVariant = Brand.surface,
                onPrimary = Brand.nearBlack,
            )) { App() }
        }
    }

    override fun onResume() {
        super.onResume()
        applySecureFlag(window, SettingsStore(this).appLock)
    }

    override fun onStop() {
        super.onStop()
        YubiKeyManager.lock()   // forget the cached YubiKey PIN when backgrounded
        // Auto-sync: push the latest config to the user's folder on background.
        if (SyncStore(this).enabled) {
            val app = applicationContext
            thread { runCatching { ConfigSync.push(app) } }
        }
    }
}

/** Toggle FLAG_SECURE so terminal/key content is excluded from the recents
 *  snapshot and screenshots whenever app lock is on. Applied at create, on
 *  resume, and the instant the setting changes — never gated on a lifecycle trip. */
fun applySecureFlag(window: android.view.Window, secure: Boolean) {
    if (secure) {
        window.setFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE,
            android.view.WindowManager.LayoutParams.FLAG_SECURE)
    } else {
        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
    }
}

private val main = Handler(Looper.getMainLooper())

/** Parse a port, returning null unless it's a valid 1..65535 — no silent
 *  fallback to 22 that could connect to / trust / save the wrong endpoint. */
fun validPort(text: String): Int? = text.trim().toIntOrNull()?.takeIf { it in 1..65535 }

/** A single ProxyJump hop. */
data class JumpSpec(val host: String, val port: Int, val user: String)

/** Outcome of parsing a ProxyJump spec. `Invalid` is distinct from `None` so an
 *  explicit-but-malformed bastion is rejected, never silently dropped or pointed
 *  at the wrong port. */
sealed interface JumpParse {
    object None : JumpParse
    data class Ok(val spec: JumpSpec) : JumpParse
    data class Invalid(val message: String) : JumpParse
}

/** Parse the first hop of a ProxyJump spec ("user@bastion[:port][,…]"). A missing
 *  user falls back to the target user; multi-hop chains use the first hop for now.
 *  A port outside 1..65535 is rejected rather than falling back to 22. */
fun parseJump(spec: String?, fallbackUser: String): JumpParse {
    val first = spec?.split(",")?.firstOrNull()?.trim()?.takeIf { it.isNotEmpty() } ?: return JumpParse.None
    val at = first.indexOf('@')
    val who = if (at >= 0) first.substring(0, at) else fallbackUser
    val hp = if (at >= 0) first.substring(at + 1) else first
    // Any colon that isn't the first char means an explicit port: require it to be
    // valid (matches iOS), so "host:", "host:abc", "host:0" are rejected rather than
    // silently treated as a hostname on port 22.
    val colon = hp.lastIndexOf(':')
    if (colon > 0) {
        val port = hp.substring(colon + 1).toIntOrNull()?.takeIf { it in 1..65535 }
            ?: return JumpParse.Invalid("jump host port must be a number from 1 to 65535")
        return JumpParse.Ok(JumpSpec(hp.substring(0, colon), port, who))
    }
    return JumpParse.Ok(JumpSpec(hp, 22, who))
}

private enum class Route { Connect, Keys, Hosts, Settings, Backup, Import, Snippets }

@Composable
fun App() {
    val context = LocalContext.current
    // The available keys: the always-present hardware Keystore key + software keys.
    val keyManager = remember { KeyManager(context) }
    var keys by remember { mutableStateOf(keyManager.keys()) }
    var selectedKeyId by remember { mutableStateOf(keys.first().id) }
    val selectedKey = keys.firstOrNull { it.id == selectedKeyId } ?: keys.first()

    val settings = remember { SettingsStore(context) }
    var showKeyBar by remember { mutableStateOf(settings.showKeyBar) }

    // Auto-sync: pull + merge the user's folder once on launch, then refresh the
    // in-memory keys/hosts (syncTick re-reads the saved list on the connect screen).
    var syncTick by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) {
        if (SyncStore(context).enabled) {
            val applied = withContext(Dispatchers.IO) { runCatching { ConfigSync.pull(context) }.getOrNull() }
            if (applied != null && !applied.isEmpty) {
                keys = keyManager.keys()
                syncTick++
            }
        }
    }

    // App lock: require device authentication at launch and after each backgrounding.
    val lockEnabled = settings.appLock && biometricAvailable(context)
    var unlocked by remember { mutableStateOf(!lockEnabled) }
    if (lockEnabled) {
        val lifecycleOwner = LocalLifecycleOwner.current
        DisposableEffect(lifecycleOwner) {
            val obs = LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_STOP) unlocked = false
            }
            lifecycleOwner.lifecycle.addObserver(obs)
            onDispose { lifecycleOwner.lifecycle.removeObserver(obs) }
        }
        if (!unlocked) { LockScreen { unlocked = true }; return }
    }

    val sessions = remember { mutableStateListOf<TerminalHolder>() }
    var activeIndex by remember { mutableStateOf(-1) }   // -1 = the connect screen
    var route by remember { mutableStateOf(Route.Connect) }
    var sftpTarget by remember { mutableStateOf<SftpTarget?>(null) }
    var forwardSession by remember { mutableStateOf<cc.bsns.ssh.transport.ForwardSession?>(null) }
    var showForwards by remember { mutableStateOf(false) }

    fun closeAt(i: Int) {
        sessions[i].close()
        sessions.removeAt(i)
        activeIndex = if (sessions.isEmpty()) -1 else activeIndex.coerceAtMost(sessions.size - 1)
    }

    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        if (sessions.isNotEmpty()) {
            TabStrip(
                titles = sessions.map { it.title },
                active = activeIndex,
                onSelect = { activeIndex = it },
                onClose = { closeAt(it) },
                onNew = { activeIndex = -1 },
            )
        }
        val target = sftpTarget
        val fwd = forwardSession
        if (showForwards && fwd != null) {
            PortForwardsScreen(
                fwd,
                onStopAll = { fwd.close(); forwardSession = null; showForwards = false },
                onClose = { showForwards = false },
            )
        } else if (target != null) {
            SftpScreen(target) { sftpTarget = null }
        } else if (activeIndex in sessions.indices) {
            TerminalPane(sessions[activeIndex], showKeyBar = showKeyBar) { closeAt(activeIndex) }
        } else when (route) {
            Route.Connect -> ConnectScreen(
                key = selectedKey,
                keys = keys,
                reloadKey = syncTick,
                onSelectKey = { selectedKeyId = it },
                onManageKeys = { route = Route.Keys },
                onManageHosts = { route = Route.Hosts },
                onSettings = { route = Route.Settings },
                onImport = { route = Route.Import },
                onSftp = { sftpTarget = it },
                forwardsActive = forwardSession != null,
                onReopenForwards = { showForwards = true },
                onForwards = { fs -> forwardSession?.close(); forwardSession = fs; showForwards = true },
            ) { session, title, factory ->
                val holder = TerminalHolder(context, session, title, factory,
                    fontSizeSp = settings.fontSize, scrollback = settings.scrollback,
                    keepAwake = settings.keepAwake, cursorBlink = settings.cursorBlink,
                    theme = Appearance.themeById(settings.theme), cursorStyle = settings.cursorStyle,
                    bellHaptic = settings.bellHaptic)
                sessions.add(holder)
                activeIndex = sessions.size - 1
                // Fire "run on connect" snippets once the shell has settled.
                val startup = SnippetStore(context).runOnConnect()
                if (startup.isNotEmpty()) main.postDelayed({
                    startup.forEach { holder.runSnippet(it.command) }
                }, 400)
            }
            Route.Keys -> KeysScreen(keyManager) {
                keys = keyManager.keys()
                if (keys.none { it.id == selectedKeyId }) selectedKeyId = keys.first().id
                route = Route.Connect
            }
            Route.Hosts -> KnownHostsScreen { route = Route.Connect }
            Route.Settings -> SettingsScreen(
                settings, biometricAvailable = biometricAvailable(context),
                onBackup = { route = Route.Backup },
                onSnippets = { route = Route.Snippets },
            ) {
                showKeyBar = settings.showKeyBar
                route = Route.Connect
            }
            Route.Backup -> BackupScreen { route = Route.Settings }
            Route.Snippets -> SnippetsScreen { route = Route.Settings }
            // Returning recreates ConnectScreen, which reloads saved hosts from disk.
            Route.Import -> ImportConfigScreen { route = Route.Connect }
        }
    }

    // Global overlay while a YubiKey operation waits for the user to tap/insert.
    YubiKeyManager.awaitingTap?.let { msg ->
        AlertDialog(
            onDismissRequest = { },
            title = { Text("YubiKey") },
            text = { Text("$msg\n\nHold your YubiKey to the back of the phone (NFC) or plug it into USB-C.") },
            confirmButton = {},
        )
    }
}

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
            BsnsSessionClient({ terminalView.onScreenUpdated() }, { vibrate() }), io)
        terminalView.setTerminalViewClient(BsnsViewClient(view = { terminalView }, onEmulatorReady = {
            wireOutput(initialSession)
            terminalView.mEmulator?.let { Appearance.apply(it, theme) }
            val esc = Appearance.cursorStyleEscape(cursorStyle)
            termSession.appendToEmulator(esc, esc.size)
            if (cursorBlink) {
                terminalView.setTerminalCursorBlinkerRate(500)
                terminalView.setTerminalCursorBlinkerState(true, true)
            }
            terminalView.invalidate()
        }))
        terminalView.attachSession(termSession)
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

    private fun wireOutput(s: TerminalTransport) {
        s.onOutput = { bytes ->
            noteOutputForSecretPrompt(bytes)
            main.post { termSession.appendToEmulator(bytes, bytes.size) }
        }
        when (s) {
            is SshSession -> s.onClosed = { _ -> onDropped() }
            is MoshSession -> {
                s.onClosed = { _ -> onDropped() }
                s.onLiveness = { stale -> main.post { isStale = stale } }
            }
        }
    }

    private fun onDropped() {
        if (!userClosing) main.post { if (status == ConnStatus.Connected) status = ConnStatus.Disconnected }
    }

    /** Rebuild the transport behind the same terminal view (the buffer persists). */
    fun reconnect() {
        if (status == ConnStatus.Reconnecting) return
        status = ConnStatus.Reconnecting
        isStale = false
        thread {
            val s = reconnectFactory()
            main.post {
                if (s != null) {
                    session = s
                    wireOutput(s)
                    terminalView.mEmulator?.let { s.resize(it.mColumns, it.mRows) }
                    status = ConnStatus.Connected
                } else status = ConnStatus.Disconnected
            }
        }
    }

    fun close() {
        userClosing = true
        session.onOutput = null
        session.close()
    }
}

@Composable
fun TabStrip(titles: List<String>, active: Int, onSelect: (Int) -> Unit, onClose: (Int) -> Unit, onNew: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(start = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        titles.forEachIndexed { i, title ->
            val sel = i == active
            TextButton(onClick = { onSelect(i) }, contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp)) {
                Text(
                    (if (sel) "● " else "") + title.substringAfter('@').take(18),
                    fontFamily = FontFamily.Monospace, fontSize = 12.sp,
                    color = if (sel) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            IconButton(onClick = { onClose(i) }, modifier = Modifier.size(28.dp)) {
                Icon(Icons.Default.Close, "close tab", modifier = Modifier.size(16.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        TextButton(onClick = onNew) {
            Icon(Icons.Default.Add, "new", modifier = Modifier.size(18.dp))
            Text("new", fontSize = 13.sp)
        }
    }
}

@Composable
fun TerminalPane(holder: TerminalHolder, showKeyBar: Boolean = true, onDisconnect: () -> Unit) {
    var searching by remember { mutableStateOf(false) }
    var showSnippets by remember { mutableStateOf(false) }
    var showHistory by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    var hits by remember { mutableStateOf<List<Int>>(emptyList()) }
    var hitIdx by remember { mutableStateOf(0) }
    val findFocus = remember { FocusRequester() }

    // When the search bar opens, take focus off the terminal View so the IME types
    // into the find field (a traditional View otherwise keeps Android focus).
    LaunchedEffect(searching) {
        if (searching) { holder.terminalView.clearFocus(); findFocus.requestFocus() }
    }

    fun runSearch(q: String) {
        query = q
        hits = TerminalSearch.matches(holder.terminalView, q)
        hitIdx = hits.size - 1            // start at the most recent match
        if (hitIdx >= 0) TerminalSearch.scrollTo(holder.terminalView, hits[hitIdx])
    }
    fun step(delta: Int) {
        if (hits.isEmpty()) return
        hitIdx = (hitIdx + delta + hits.size) % hits.size
        TerminalSearch.scrollTo(holder.terminalView, hits[hitIdx])
    }
    fun closeSearch() {
        searching = false; query = ""; hits = emptyList()
        TerminalSearch.toBottom(holder.terminalView)
    }

    Column(Modifier.fillMaxSize().imePadding()) {
        if (searching) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedTextField(
                    query, { runSearch(it) },
                    label = { Text("find") }, singleLine = true,
                    modifier = Modifier.weight(1f).focusRequester(findFocus),
                )
                Text(
                    if (hits.isEmpty()) "0/0" else "${hitIdx + 1}/${hits.size}",
                    fontFamily = FontFamily.Monospace, fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 6.dp),
                )
                IconButton(onClick = { step(-1) }) { Icon(Icons.Default.KeyboardArrowUp, "previous match") }
                IconButton(onClick = { step(1) }) { Icon(Icons.Default.KeyboardArrowDown, "next match") }
                IconButton(onClick = { closeSearch() }) { Icon(Icons.Default.Close, "close search") }
            }
        } else {
            Row(
                Modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Flex + ellipsize the title so a long (jumped) title never pushes the
                // action buttons off the right edge.
                Text(holder.title, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                    maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { showHistory = true }) { Icon(Icons.Default.History, "command history") }
                    IconButton(onClick = { showSnippets = true }) { Icon(Icons.Default.Code, "snippets") }
                    IconButton(onClick = { searching = true }) { Icon(Icons.Default.Search, "find") }
                    OutlinedButton(onClick = onDisconnect) { Text("Disconnect") }
                }
            }
        }
        if (holder.status != ConnStatus.Connected) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    if (holder.status == ConnStatus.Reconnecting) "Reconnecting…" else "Disconnected",
                    fontSize = 13.sp, color = MaterialTheme.colorScheme.error,
                )
                if (holder.status == ConnStatus.Disconnected) {
                    Button(onClick = { holder.reconnect() }) { Text("Reconnect") }
                }
            }
        } else if (holder.isStale) {
            // mosh stays "Connected" while it roams, but flag prolonged silence so a
            // dead session isn't shown as live (amber, not the error red).
            Text(
                "mosh: no contact with the server — it may have dropped",
                fontSize = 13.sp, color = Color(0xFFB8860B),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            )
        }
        AndroidView(
            factory = { FrameLayout(it) },
            update = { container ->
                val v = holder.terminalView
                if (v.parent !== container) {
                    (v.parent as? ViewGroup)?.removeView(v)
                    container.removeAllViews()
                    container.addView(v)
                }
                if (!searching) v.requestFocus()   // let the search field keep focus
            },
            modifier = Modifier.weight(1f).fillMaxWidth(),
        )
        // Local autocomplete: chips from your own command history (no phone-home).
        val suggestions = holder.suggestionsFor(holder.currentLine)
        if (suggestions.isNotEmpty()) {
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                suggestions.forEach { s ->
                    OutlinedButton(onClick = { holder.applyCompletion(s) },
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp)) {
                        Text(s, fontFamily = FontFamily.Monospace, fontSize = 12.sp, maxLines = 1)
                    }
                }
            }
        }
        if (showKeyBar) KeyBar { holder.session.write(it) }
    }

    if (showSnippets) SnippetPickerDialog(
        onPick = { holder.runSnippet(it.command); showSnippets = false },
        onDismiss = { showSnippets = false },
    )

    if (showHistory) {
        val items = remember(showHistory) { holder.history() }
        AlertDialog(
            onDismissRequest = { showHistory = false },
            title = { Text("Command history") },
            text = {
                if (items.isEmpty()) Text("No history yet — run a few commands.", fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                else Column(Modifier.verticalScroll(rememberScrollState())) {
                    items.take(60).forEach { cmd ->
                        Text(cmd, fontFamily = FontFamily.Monospace, fontSize = 13.sp,
                            maxLines = 1,
                            modifier = Modifier.fillMaxWidth()
                                .clickable { holder.runSnippet(cmd); showHistory = false }
                                .padding(vertical = 6.dp))
                    }
                }
            },
            confirmButton = {
                if (items.isNotEmpty()) TextButton(onClick = { holder.clearHistory(); showHistory = false }) { Text("Clear") }
            },
            dismissButton = { TextButton(onClick = { showHistory = false }) { Text("Close") } },
        )
    }
}

@Composable
fun ConnectScreen(
    key: AppKey,
    keys: List<AppKey>,
    reloadKey: Int = 0,
    onSelectKey: (String) -> Unit,
    onManageKeys: () -> Unit,
    onManageHosts: () -> Unit,
    onSettings: () -> Unit,
    onImport: () -> Unit,
    onSftp: (SftpTarget) -> Unit,
    forwardsActive: Boolean,
    onReopenForwards: () -> Unit,
    onForwards: (cc.bsns.ssh.transport.ForwardSession) -> Unit,
    onConnected: (TerminalTransport, String, () -> TerminalTransport?) -> Unit,
) {
    // Debug builds prefill the local emulator sshd for fast iteration; release
    // builds start blank with the standard SSH port.
    var host by remember { mutableStateOf(if (BuildConfig.DEBUG) "10.0.2.2" else "") }
    var port by remember { mutableStateOf(if (BuildConfig.DEBUG) "2222" else "22") }
    var user by remember { mutableStateOf(if (BuildConfig.DEBUG) "tester" else "") }
    var group by remember { mutableStateOf("") }
    var jump by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var showPassword by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var useMosh by remember { mutableStateOf(false) }
    var showYubiPin by remember { mutableStateOf(false) }
    var yubiPin by remember { mutableStateOf("") }
    var afterPin by remember { mutableStateOf<(() -> Unit)?>(null) }

    val authLine = key.authLine

    // A YubiKey signs only after its PIN is supplied — prompt once, then proceed.
    fun withYubiPin(action: () -> Unit) {
        if (key.yubiKey && !YubiKeyManager.unlocked) { afterPin = action; showYubiPin = true } else action()
    }

    val context = LocalContext.current
    val hostStore = remember { HostStore(context) }
    // reloadKey bumps after an auto-sync pull so freshly-merged hosts appear.
    var savedHosts by remember(reloadKey) { mutableStateOf(hostStore.load()) }
    val knownHosts = remember { KnownHostsStore(context) }
    var pendingTofu by remember { mutableStateOf<TofuInfo?>(null) }
    var pendingBastionTofu by remember { mutableStateOf<BastionTofu?>(null) }
    var pendingMismatch by remember { mutableStateOf<MismatchInfo?>(null) }
    var pendingAction by remember { mutableStateOf<((Int, ByteArray) -> Unit)?>(null) }

    fun openWith(p: Int, blob: ByteArray) {
        busy = true; status = "connecting…"
        // verifyThen already validated the jump spec, so anything but Ok is treated
        // as no jump here.
        val js = (parseJump(jump.trim().ifEmpty { null }, user) as? JumpParse.Ok)?.spec
        val title = if (js != null) "$user@$host:$p ⇢ ${js.host}" else "$user@$host:$p"
        // The bastion was verified by verifyThen, so its trusted key is in the store —
        // pin it on the tunnel so the bastion is re-verified on connect + reconnect.
        val bastionKey = js?.let { knownHosts.trustedBlob(it.host, it.port) }
        // The same factory does the initial open and any later reconnect-on-drop.
        val factory: () -> TerminalTransport? = {
            val s = SshSession(host, p, user, key.publicKeyBlob, key.signer, expectedHostKey = blob,
                jumpHost = js?.host, jumpPort = js?.port ?: 22, jumpUser = js?.user,
                expectedBastionHostKey = bastionKey)
            if (s.open(80, 24)) s else null
        }
        thread {
            val s = factory()
            if (s != null) main.post { busy = false; onConnected(s, title, factory) }
            else main.post { busy = false; status = "couldn't open the session (is your key installed?)" }
        }
    }

    // Open a dedicated forwarding connection (host key already verified).
    fun openForwards(p: Int, blob: ByteArray) {
        busy = true; status = "opening tunnel connection…"
        thread {
            val fs = cc.bsns.ssh.transport.ForwardSession(host, p, user, key.publicKeyBlob, key.signer, expectedHostKey = blob)
            if (fs.open()) main.post { busy = false; onForwards(fs) }
            else main.post { busy = false; status = "couldn't open the tunnel connection" }
        }
    }

    // mosh: SSH in (host-key pinned) → run mosh-server → parse MOSH CONNECT → open
    // the UDP transport. The factory re-bootstraps on a dropped/expired session.
    fun openMosh(p: Int, blob: ByteArray) {
        busy = true; status = "starting mosh-server…"
        val factory: () -> TerminalTransport? = {
            val out = SshBridge().nativeAuthAndExec(host, p, user, key.publicKeyBlob, key.signer,
                MoshBootstrap.SERVER_CMD, blob)
            val conn = MoshBootstrap.parse(out)
            if (conn != null) {
                val m = MoshSession(host, conn.port, conn.key)
                if (m.open(80, 24)) m else null
            } else null
        }
        thread {
            val m = factory()
            if (m != null) main.post { busy = false; onConnected(m, "mosh·$user@$host", factory) }
            else main.post { busy = false; status = "mosh-server didn't start (is mosh on the host?)" }
        }
    }

    // Verify the host key (TOFU), then run the chosen action. With a jump host this
    // is two-stage: trust the BASTION's own key first (before any auth to it), then
    // the target's key fetched through the now-verified tunnel.
    fun verifyThen(action: (Int, ByteArray) -> Unit) {
        val p = validPort(port)
        if (p == null) { status = "port must be a number from 1 to 65535"; return }
        val js = when (val j = parseJump(jump.trim().ifEmpty { null }, user)) {
            is JumpParse.Invalid -> { status = j.message; return }
            is JumpParse.Ok -> j.spec
            JumpParse.None -> null
        }
        busy = true; status = if (js != null) "verifying jump host ${js.host}…" else "verifying host…"
        thread {
            // Stage 1: the bastion's own key (direct), trusted before we auth to it.
            val bastionKey: ByteArray?
            if (js != null) {
                val bkey = SshBridge().nativeHostKeyBlob(js.host, js.port)
                if (bkey == null) { main.post { busy = false; status = "couldn't reach jump host ${js.host}:${js.port}" }; return@thread }
                val bt = knownHosts.trustedBlob(js.host, js.port)
                when {
                    bt == null -> { main.post { busy = false; pendingAction = action; pendingBastionTofu = BastionTofu(js.host, js.port, bkey) }; return@thread }
                    !bt.contentEquals(bkey) -> { main.post { busy = false
                        pendingAction = action
                        pendingMismatch = MismatchInfo(js.host, js.port, bt, bkey, isJump = true) }; return@thread }
                }
                bastionKey = bkey
            } else bastionKey = null

            // Stage 2: the target's key — fetched THROUGH the tunnel (re-verifying the
            // bastion) for a jump, or directly otherwise. Compose state must change
            // on the main thread, never this worker.
            if (js != null) main.post { status = "verifying host via ${js.host}…" }
            val blob = if (js != null)
                SshBridge().nativeHostKeyBlobVia(host, p, js.host, js.port, js.user, key.publicKeyBlob, key.signer, bastionKey)
            else SshBridge().nativeHostKeyBlob(host, p)
            val trusted = if (blob != null) knownHosts.trustedBlob(host, p) else null
            when {
                blob == null -> main.post { busy = false; status = "couldn't reach $host:$p" }
                trusted == null -> main.post { busy = false; pendingAction = action; pendingTofu = TofuInfo(p, blob) }
                !trusted.contentEquals(blob) -> main.post {
                    busy = false
                    pendingAction = action
                    pendingMismatch = MismatchInfo(host, p, trusted, blob, isJump = false)
                }
                else -> main.post { busy = false; action(p, blob) }
            }
        }
    }

    val hasJump = jump.trim().isNotEmpty()
    var showPublicKey by remember { mutableStateOf(false) }
    Scaffold { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(Spacing.screen).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(Spacing.section),
        ) {
            // App bar: brand wordmark + nav.
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                Text("bsns.\$_", fontFamily = FontFamily.Monospace, fontSize = 22.sp)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = onManageKeys) { Text("Keys") }
                    TextButton(onClick = onManageHosts) { Text("Hosts") }
                    IconButton(onClick = onSettings) { Icon(Icons.Default.Settings, "Settings") }
                }
            }

            // Saved hosts — one card per folder.
            if (savedHosts.isNotEmpty()) {
                val grouped = savedHosts.groupBy { it.group?.trim()?.ifEmpty { null } }
                val sections = grouped.keys.filterNotNull().sorted() + (if (grouped.containsKey(null)) listOf<String?>(null) else emptyList())
                sections.forEach { g ->
                    Section(title = g ?: "Saved hosts") {
                        grouped[g]!!.forEachIndexed { i, h ->
                            if (i > 0) RowDivider()
                            Row(
                                // Whole row loads the host (a big, reliable tap target); the ✕ removes it.
                                Modifier.fillMaxWidth().heightIn(min = Spacing.rowMinHeight).clickable {
                                    host = h.host; port = h.port.toString(); user = h.user
                                    group = h.group ?: ""; jump = h.jump ?: ""
                                    if (h.keyId != null && keys.any { it.id == h.keyId }) onSelectKey(h.keyId)
                                    status = "loaded ${h.label}"
                                },
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(Modifier.weight(1f).padding(vertical = 6.dp)) {
                                    Text(h.label, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                                        color = MaterialTheme.colorScheme.primary)
                                    h.jump?.let {
                                        Text("⇢ $it", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                }
                                IconButton(onClick = { savedHosts = hostStore.remove(h) }) {
                                    Icon(Icons.Default.Close, "remove", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                    }
                }
            }

            // Connection inputs.
            Section(title = "Server", footer = "Connect over SSH — your key stays in the Keystore.") {
                Column(Modifier.padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(host, { host = it }, label = { Text("host") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(port, { port = it }, label = { Text("port") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(user, { user = it }, label = { Text("user") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(group, { group = it }, label = { Text("group (optional)") },
                        singleLine = true, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(jump, { jump = it }, label = { Text("jump / bastion (optional: user@host[:port])") },
                        singleLine = true, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(
                        password, { password = it },
                        label = { Text("password (only to install your key)") },
                        singleLine = true,
                        visualTransformation = if (showPassword) androidx.compose.ui.text.input.VisualTransformation.None
                            else androidx.compose.ui.text.input.PasswordVisualTransformation(),
                        trailingIcon = {
                            TextButton(onClick = { showPassword = !showPassword }) {
                                Text(if (showPassword) "hide" else "show", fontSize = 12.sp)
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                RowDivider()
                SettingRow("Use mosh (UDP — roams, survives sleep)", enabled = !hasJump) {
                    androidx.compose.material3.Switch(checked = useMosh, enabled = !hasJump,
                        onCheckedChange = { useMosh = it })
                }
                if (keys.size > 1) {
                    RowDivider()
                    Box(Modifier.padding(vertical = 8.dp)) { KeyPicker(keys, key.id, onSelectKey) }
                }
            }

            if (hasJump) {
                Text("Via a jump host, only an interactive shell is supported for now — " +
                    "mosh, Files, Tunnels, and Install key go direct and are disabled.",
                    fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }

            // Actions.
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(
                    Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Button(enabled = !busy, onClick = {
                        // A jump host tunnels the shell only; ignore mosh when one is set.
                        withYubiPin { verifyThen { p, blob -> if (useMosh && !hasJump) openMosh(p, blob) else openWith(p, blob) } }
                    }) { Text(if (useMosh && !hasJump) "Connect (mosh)" else "Connect") }

                    OutlinedButton(enabled = !busy && !hasJump, onClick = {
                        withYubiPin {
                            verifyThen { p, blob ->
                                onSftp(SftpTarget(host, p, user, key.publicKeyBlob, key.signer, blob))
                            }
                        }
                    }) { Text("Files") }

                    OutlinedButton(enabled = !busy && !hasJump, onClick = {
                        if (forwardsActive) onReopenForwards()
                        else withYubiPin { verifyThen { p, blob -> openForwards(p, blob) } }
                    }) { Text(if (forwardsActive) "Tunnels ●" else "Tunnels") }

                    OutlinedButton(enabled = !busy && password.isNotEmpty() && !hasJump, onClick = {
                        // Verify the host key first (same TOFU prompt as Connect) so the
                        // server password is never sent to an unverified host.
                        verifyThen { p, blob ->
                            busy = true; status = "installing key…"
                            thread {
                                val ok = SshBridge().nativeInstallKey(host, p, user, password, authLine, blob)
                                main.post {
                                    busy = false
                                    if (ok) password = ""   // don't keep the password in UI state after use
                                    status = if (ok) "key installed — now Connect" else "install failed"
                                }
                            }
                        }
                    }) { Text("Install key") }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(
                        enabled = host.isNotBlank() && user.isNotBlank(),
                        onClick = {
                            val p = validPort(port)
                            if (p == null) { status = "port must be a number from 1 to 65535"; return@OutlinedButton }
                            savedHosts = hostStore.add(SavedHost(host, p, user,
                                jump = jump.trim().ifEmpty { null }, group = group.trim().ifEmpty { null },
                                keyId = key.id))
                            status = "saved $user@$host"
                        },
                    ) { Text("Save host") }
                    TextButton(onClick = onImport) { Text("Import from ~/.ssh", fontSize = 13.sp) }
                }
                status?.let { Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.primary) }
            }

            // The public key is a wall of base64, rarely needed — keep it in a card, collapsed.
            Section {
                Row(
                    Modifier.fillMaxWidth().heightIn(min = Spacing.rowMinHeight)
                        .clickable { showPublicKey = !showPublicKey },
                    horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("My public key", fontSize = 15.sp)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = { copyToClipboard(context, "public key", authLine) }) { Text("Copy") }
                        Icon(if (showPublicKey) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                            contentDescription = if (showPublicKey) "hide" else "show",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (showPublicKey) {
                    Text("Add to the server's ~/.ssh/authorized_keys:", fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(bottom = 4.dp))
                    SelectionContainer {
                        Text(authLine, fontFamily = FontFamily.Monospace, fontSize = 10.sp,
                            modifier = Modifier.padding(bottom = 8.dp))
                    }
                }
            }

            pendingTofu?.let { tofu ->
                val fp = remember(tofu) { SshKeyFormat.fingerprintOfPublicKeyBlob(tofu.blob) }
                AlertDialog(
                    onDismissRequest = { pendingTofu = null },
                    title = { Text("Verify host key") },
                    text = {
                        Text(
                            "First connection to $user@$host:${tofu.port}.\n\n$fp\n\n" +
                                "Only trust this if the fingerprint matches what the server's admin gave you out of band.",
                        )
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            knownHosts.trust(host, tofu.port, tofu.blob)
                            val info = tofu
                            val act = pendingAction
                            pendingTofu = null
                            pendingAction = null
                            (act ?: { p, b -> openWith(p, b) })(info.port, info.blob)
                        }) { Text("Trust") }
                    },
                    dismissButton = {
                        TextButton(onClick = { pendingTofu = null; pendingAction = null }) { Text("Cancel") }
                    },
                )
            }

            pendingBastionTofu?.let { bt ->
                val fp = remember(bt) { SshKeyFormat.fingerprintOfPublicKeyBlob(bt.blob) }
                AlertDialog(
                    onDismissRequest = { pendingBastionTofu = null; pendingAction = null },
                    title = { Text("Verify jump host key") },
                    text = {
                        Text(
                            "First connection to the jump host ${bt.host}:${bt.port}.\n\n$fp\n\n" +
                                "You're routing through this bastion to reach $host. Trust it only if the " +
                                "fingerprint matches what its admin gave you out of band.",
                        )
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            knownHosts.trust(bt.host, bt.port, bt.blob)
                            val act = pendingAction
                            pendingBastionTofu = null
                            // Bastion now trusted → re-run verification (proceeds to the target).
                            if (act != null) verifyThen(act)
                        }) { Text("Trust") }
                    },
                    dismissButton = {
                        TextButton(onClick = { pendingBastionTofu = null; pendingAction = null }) { Text("Cancel") }
                    },
                )
            }

            pendingMismatch?.let { mm ->
                val storedFp = remember(mm) { SshKeyFormat.fingerprintOfPublicKeyBlob(mm.stored) }
                val presentedFp = remember(mm) { SshKeyFormat.fingerprintOfPublicKeyBlob(mm.presented) }
                val label = if (mm.isJump) "jump host" else "host"
                AlertDialog(
                    onDismissRequest = { pendingMismatch = null; pendingAction = null },
                    title = { Text("⚠ Host key changed") },
                    text = {
                        Text(
                            "The $label key for ${mm.host}:${mm.port} no longer matches the one you " +
                                "trusted. This can mean the server was rebuilt — or that someone is " +
                                "intercepting the connection.\n\n" +
                                "trusted:  $storedFp\n" +
                                "now:      $presentedFp\n\n" +
                                "Only forget the saved key if you verified the new fingerprint out of band. " +
                                "You'll be asked to verify it again before connecting.",
                        )
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            // Forget the stale key, then re-run verification — which falls
                            // through to a fresh TOFU prompt on the new key (never a silent
                            // re-trust). For a jump mismatch, verifyThen re-checks the bastion
                            // first; for a target mismatch it re-checks the target.
                            knownHosts.forget(mm.host, mm.port)
                            val act = pendingAction
                            pendingMismatch = null
                            if (act != null) verifyThen(act)
                        }) { Text("Forget key") }
                    },
                    dismissButton = {
                        TextButton(onClick = { pendingMismatch = null; pendingAction = null }) { Text("Cancel") }
                    },
                )
            }

            if (showYubiPin) {
                AlertDialog(
                    onDismissRequest = { showYubiPin = false; yubiPin = ""; afterPin = null },
                    title = { Text("YubiKey PIN") },
                    text = {
                        OutlinedTextField(yubiPin, { yubiPin = it }, label = { Text("PIN") }, singleLine = true,
                            visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation())
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            YubiKeyManager.setPin(yubiPin); yubiPin = ""; showYubiPin = false
                            val act = afterPin; afterPin = null; act?.invoke()
                        }) { Text("Continue") }
                    },
                    dismissButton = {
                        TextButton(onClick = { showYubiPin = false; yubiPin = ""; afterPin = null }) { Text("Cancel") }
                    },
                )
            }
        }
    }
}

private class TofuInfo(val port: Int, val blob: ByteArray)
private class BastionTofu(val host: String, val port: Int, val blob: ByteArray)

/** A host whose presented key no longer matches the one we trusted. Carries
 *  everything the recovery dialog needs to forget the stale key and re-verify.
 *  `isJump` distinguishes the bastion's own key from the target's. */
private class MismatchInfo(
    val host: String,
    val port: Int,
    val stored: ByteArray,
    val presented: ByteArray,
    val isJump: Boolean,
)


private fun seq(vararg b: Int) = ByteArray(b.size) { b[it].toByte() }

/** Keys missing from soft keyboards but essential in a terminal. */
@Composable
private fun KeyBar(onKey: (ByteArray) -> Unit) {
    val keys = listOf(
        "esc" to seq(0x1B), "tab" to seq(0x09),
        "^C" to seq(0x03), "^D" to seq(0x04), "^Z" to seq(0x1A), "^L" to seq(0x0C),
        "←" to seq(0x1B, 0x5B, 0x44), "↑" to seq(0x1B, 0x5B, 0x41),
        "↓" to seq(0x1B, 0x5B, 0x42), "→" to seq(0x1B, 0x5B, 0x43),
        "|" to seq('|'.code), "~" to seq('~'.code), "/" to seq('/'.code), "-" to seq('-'.code),
    )
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
        keys.forEach { (label, bytes) ->
            TextButton(onClick = { onKey(bytes) }) {
                Text(label, fontFamily = FontFamily.Monospace, fontSize = 15.sp)
            }
        }
    }
}
