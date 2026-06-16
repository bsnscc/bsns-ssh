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
import androidx.compose.foundation.layout.Column
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
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
        setContent { MaterialTheme(colorScheme = darkColorScheme()) { App() } }
    }
}

private val main = Handler(Looper.getMainLooper())

private enum class Route { Connect, Keys, Hosts, Settings, Backup }

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
                onSelectKey = { selectedKeyId = it },
                onManageKeys = { route = Route.Keys },
                onManageHosts = { route = Route.Hosts },
                onSettings = { route = Route.Settings },
                onSftp = { sftpTarget = it },
                forwardsActive = forwardSession != null,
                onReopenForwards = { showForwards = true },
                onForwards = { fs -> forwardSession?.close(); forwardSession = fs; showForwards = true },
            ) { session, title ->
                sessions.add(TerminalHolder(context, session, title,
                    fontSizeSp = settings.fontSize, scrollback = settings.scrollback,
                    keepAwake = settings.keepAwake, cursorBlink = settings.cursorBlink))
                activeIndex = sessions.size - 1
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
            ) {
                showKeyBar = settings.showKeyBar
                route = Route.Connect
            }
            Route.Backup -> BackupScreen { route = Route.Settings }
        }
    }
}

/**
 * Holds one session's TerminalView + emulator outside composition so the buffer
 * survives tab switches. Created once when a session connects (iOS surface-cache
 * analogue).
 */
class TerminalHolder(
    context: android.content.Context,
    val session: TerminalTransport,
    val title: String,
    fontSizeSp: Int = 14,
    scrollback: Int = 5000,
    keepAwake: Boolean = true,
    cursorBlink: Boolean = true,
) {
    val terminalView = TerminalView(context, null).apply {
        setTextSize((fontSizeSp * resources.displayMetrics.scaledDensity).toInt())
        setTypeface(Typeface.MONOSPACE)
        keepScreenOn = keepAwake
        isFocusableInTouchMode = true
    }

    init {
        val io = object : TerminalSession.ExternalIo {
            override fun write(data: ByteArray, offset: Int, count: Int) =
                session.write(data.copyOfRange(offset, offset + count))
            override fun onResize(columns: Int, rows: Int) = session.resize(columns, rows)
        }
        val termSession = TerminalSession(scrollback, BsnsSessionClient { terminalView.onScreenUpdated() }, io)
        terminalView.setTerminalViewClient(BsnsViewClient(view = { terminalView }, onEmulatorReady = {
            session.onOutput = { bytes -> main.post { termSession.appendToEmulator(bytes, bytes.size) } }
            if (cursorBlink) {
                terminalView.setTerminalCursorBlinkerRate(500)
                terminalView.setTerminalCursorBlinkerState(true, true)
            }
        }))
        terminalView.attachSession(termSession)
    }

    fun close() {
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
            TextButton(onClick = { onClose(i) }, contentPadding = PaddingValues(2.dp)) {
                Text("✕", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        TextButton(onClick = onNew) { Text("+ new", fontSize = 13.sp) }
    }
}

@Composable
fun TerminalPane(holder: TerminalHolder, showKeyBar: Boolean = true, onDisconnect: () -> Unit) {
    var searching by remember { mutableStateOf(false) }
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
                TextButton(onClick = { step(-1) }, contentPadding = PaddingValues(4.dp)) { Text("↑") }
                TextButton(onClick = { step(1) }, contentPadding = PaddingValues(4.dp)) { Text("↓") }
                TextButton(onClick = { closeSearch() }, contentPadding = PaddingValues(4.dp)) { Text("✕") }
            }
        } else {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(holder.title, fontFamily = FontFamily.Monospace, fontSize = 14.sp)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = { searching = true }) { Text("⌕") }
                    OutlinedButton(onClick = onDisconnect) { Text("Disconnect") }
                }
            }
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
        if (showKeyBar) KeyBar { holder.session.write(it) }
    }
}

@Composable
fun ConnectScreen(
    key: AppKey,
    keys: List<AppKey>,
    onSelectKey: (String) -> Unit,
    onManageKeys: () -> Unit,
    onManageHosts: () -> Unit,
    onSettings: () -> Unit,
    onSftp: (SftpTarget) -> Unit,
    forwardsActive: Boolean,
    onReopenForwards: () -> Unit,
    onForwards: (cc.bsns.ssh.transport.ForwardSession) -> Unit,
    onConnected: (TerminalTransport, String) -> Unit,
) {
    var host by remember { mutableStateOf("10.0.2.2") }
    var port by remember { mutableStateOf("2222") }
    var user by remember { mutableStateOf("tester") }
    var password by remember { mutableStateOf("") }
    var status by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var useMosh by remember { mutableStateOf(false) }

    val authLine = key.authLine

    val context = LocalContext.current
    val hostStore = remember { HostStore(context) }
    var savedHosts by remember { mutableStateOf(hostStore.load()) }
    val knownHosts = remember { KnownHostsStore(context) }
    var pendingTofu by remember { mutableStateOf<TofuInfo?>(null) }
    var pendingAction by remember { mutableStateOf<((Int, ByteArray) -> Unit)?>(null) }

    fun openWith(p: Int, blob: ByteArray) {
        busy = true; status = "connecting…"
        thread {
            val s = SshSession(host, p, user, key.publicKeyBlob, key.signer, expectedHostKey = blob)
            if (s.open(80, 24)) main.post { busy = false; onConnected(s, "$user@$host:$p") }
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

    // mosh: SSH in (host-key already verified) → run mosh-server → parse MOSH
    // CONNECT → open the UDP transport to host:<udp-port> with that key.
    fun openMosh(p: Int) {
        busy = true; status = "starting mosh-server…"
        thread {
            val out = SshBridge().nativeAuthAndExec(host, p, user, key.publicKeyBlob, key.signer, MoshBootstrap.SERVER_CMD)
            val conn = MoshBootstrap.parse(out)
            if (conn == null) {
                main.post { busy = false; status = "mosh-server didn't start (is mosh on the host?)" }
                return@thread
            }
            main.post { status = "opening mosh udp ${conn.port}…" }
            val m = MoshSession(host, conn.port, conn.key)
            if (m.open(80, 24)) main.post { busy = false; onConnected(m, "mosh·$user@$host") }
            else main.post { busy = false; status = "couldn't open the mosh UDP transport" }
        }
    }

    // Verify the host key (TOFU) once, then run the chosen action (shell or SFTP).
    fun verifyThen(action: (Int, ByteArray) -> Unit) {
        busy = true; status = "verifying host…"
        thread {
            val p = port.toIntOrNull() ?: 22
            val blob = SshBridge().nativeHostKeyBlob(host, p)
            val trusted = if (blob != null) knownHosts.trustedBlob(host, p) else null
            when {
                blob == null -> main.post { busy = false; status = "couldn't reach $host:$p" }
                trusted == null -> main.post { busy = false; pendingAction = action; pendingTofu = TofuInfo(p, blob) }
                !trusted.contentEquals(blob) -> main.post {
                    busy = false
                    status = "⚠ host key CHANGED for $host — refusing (possible interception)"
                }
                else -> main.post { busy = false; action(p, blob) }
            }
        }
    }

    Scaffold { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                Text("bsns.\$_", fontFamily = FontFamily.Monospace, fontSize = 22.sp)
                Row {
                    TextButton(onClick = onManageKeys) { Text("Keys") }
                    TextButton(onClick = onManageHosts) { Text("Hosts") }
                    TextButton(onClick = onSettings) { Text("⚙") }
                }
            }
            Text("Connect over SSH — your key stays in the Keystore.", fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant)

            if (savedHosts.isNotEmpty()) {
                Text("Saved", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                savedHosts.forEach { h ->
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            h.label, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                            color = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.weight(1f).clickable {
                                host = h.host; port = h.port.toString(); user = h.user
                            },
                        )
                        TextButton(onClick = { savedHosts = hostStore.remove(h) }) { Text("✕") }
                    }
                }
            }

            OutlinedTextField(host, { host = it }, label = { Text("host") }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(port, { port = it }, label = { Text("port") }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(user, { user = it }, label = { Text("user") }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(password, { password = it }, label = { Text("password (only to install your key)") },
                modifier = Modifier.fillMaxWidth())

            if (keys.size > 1) KeyPicker(keys, key.id, onSelectKey)

            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Use mosh (UDP — roams, survives sleep)", fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                androidx.compose.material3.Switch(checked = useMosh, onCheckedChange = { useMosh = it })
            }

            Row(
                Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Button(enabled = !busy, onClick = {
                    verifyThen { p, blob -> if (useMosh) openMosh(p) else openWith(p, blob) }
                }) { Text(if (useMosh) "Connect (mosh)" else "Connect") }

                OutlinedButton(enabled = !busy, onClick = {
                    verifyThen { p, blob ->
                        onSftp(SftpTarget(host, p, user, key.publicKeyBlob, key.signer, blob))
                    }
                }) { Text("Files") }

                OutlinedButton(enabled = !busy, onClick = {
                    if (forwardsActive) onReopenForwards()
                    else verifyThen { p, blob -> openForwards(p, blob) }
                }) { Text(if (forwardsActive) "Tunnels ●" else "Tunnels") }

                OutlinedButton(enabled = !busy && password.isNotEmpty(), onClick = {
                    busy = true; status = "installing key…"
                    thread {
                        val p = port.toIntOrNull() ?: 22
                        val ok = SshBridge().nativeInstallKey(host, p, user, password, authLine)
                        main.post { busy = false; status = if (ok) "key installed — now Connect" else "install failed" }
                    }
                }) { Text("Install key") }

                OutlinedButton(
                    enabled = host.isNotBlank() && user.isNotBlank(),
                    onClick = { savedHosts = hostStore.add(SavedHost(host, port.toIntOrNull() ?: 22, user)) },
                ) { Text("Save") }
            }

            status?.let { Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.primary) }

            Text("Your public key (add to the server's ~/.ssh/authorized_keys):",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp))
            SelectionContainer {
                Text(authLine, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
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
        }
    }
}

private class TofuInfo(val port: Int, val blob: ByteArray)


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
