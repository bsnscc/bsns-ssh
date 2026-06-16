package cc.bsns.ssh

import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import cc.bsns.ssh.core.SshKeyFormat
import cc.bsns.ssh.transport.KeystoreSigner
import cc.bsns.ssh.transport.SshBridge
import cc.bsns.ssh.transport.SshSession
import java.util.Base64
import kotlin.concurrent.thread

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme(colorScheme = darkColorScheme()) { App() } }
    }
}

private val main = Handler(Looper.getMainLooper())

@Composable
fun App() {
    val context = LocalContext.current
    // The app's identity: a non-extractable Keystore key (TEE; StrongBox on device).
    val signer = remember { KeystoreSigner("bsns-app-key") }
    val sessions = remember { mutableStateListOf<TerminalHolder>() }
    var activeIndex by remember { mutableStateOf(-1) }   // -1 = the connect screen

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
        if (activeIndex in sessions.indices) {
            TerminalPane(sessions[activeIndex]) { closeAt(activeIndex) }
        } else {
            ConnectScreen(signer) { session, title ->
                sessions.add(TerminalHolder(context, session, title))
                activeIndex = sessions.size - 1
            }
        }
    }
}

/**
 * Holds one session's TerminalView + emulator outside composition so the buffer
 * survives tab switches. Created once when a session connects (iOS surface-cache
 * analogue).
 */
class TerminalHolder(context: android.content.Context, val session: SshSession, val title: String) {
    val terminalView = TerminalView(context, null).apply {
        setTextSize((14 * resources.displayMetrics.scaledDensity).toInt())
        setTypeface(Typeface.MONOSPACE)
        keepScreenOn = true
        isFocusableInTouchMode = true
    }

    init {
        val io = object : TerminalSession.ExternalIo {
            override fun write(data: ByteArray, offset: Int, count: Int) =
                session.write(data.copyOfRange(offset, offset + count))
            override fun onResize(columns: Int, rows: Int) = session.resize(columns, rows)
        }
        val termSession = TerminalSession(5000, BsnsSessionClient { terminalView.onScreenUpdated() }, io)
        terminalView.setTerminalViewClient(BsnsViewClient(view = { terminalView }, onEmulatorReady = {
            session.onOutput = { bytes -> main.post { termSession.appendToEmulator(bytes, bytes.size) } }
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
fun TerminalPane(holder: TerminalHolder, onDisconnect: () -> Unit) {
    Column(Modifier.fillMaxSize().imePadding()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(holder.title, fontFamily = FontFamily.Monospace, fontSize = 14.sp)
            OutlinedButton(onClick = onDisconnect) { Text("Disconnect") }
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
                v.requestFocus()
            },
            modifier = Modifier.weight(1f).fillMaxWidth(),
        )
        KeyBar { holder.session.write(it) }
    }
}

@Composable
fun ConnectScreen(signer: KeystoreSigner, onConnected: (SshSession, String) -> Unit) {
    var host by remember { mutableStateOf("10.0.2.2") }
    var port by remember { mutableStateOf("2222") }
    var user by remember { mutableStateOf("tester") }
    var password by remember { mutableStateOf("") }
    var status by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    val authLine = remember {
        "ecdsa-sha2-nistp256 " + Base64.getEncoder().encodeToString(signer.publicKeyBlob) + " bsns"
    }

    val context = LocalContext.current
    val hostStore = remember { HostStore(context) }
    var savedHosts by remember { mutableStateOf(hostStore.load()) }
    val knownHosts = remember { KnownHostsStore(context) }
    var pendingTofu by remember { mutableStateOf<TofuInfo?>(null) }

    fun openWith(p: Int, blob: ByteArray) {
        busy = true; status = "connecting…"
        thread {
            val s = SshSession(host, p, user, signer.publicKeyBlob, signer, expectedHostKey = blob)
            if (s.open(80, 24)) main.post { busy = false; onConnected(s, "$user@$host:$p") }
            else main.post { busy = false; status = "couldn't open the session (is your key installed?)" }
        }
    }

    Scaffold { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("bsns.\$_", fontFamily = FontFamily.Monospace, fontSize = 22.sp)
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

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(enabled = !busy, onClick = {
                    busy = true; status = "verifying host…"
                    thread {
                        val p = port.toIntOrNull() ?: 22
                        val blob = SshBridge().nativeHostKeyBlob(host, p)
                        val trusted = if (blob != null) knownHosts.trustedBlob(host, p) else null
                        when {
                            blob == null -> main.post { busy = false; status = "couldn't reach $host:$p" }
                            trusted == null -> main.post { busy = false; pendingTofu = TofuInfo(p, blob) }
                            !trusted.contentEquals(blob) -> main.post {
                                busy = false
                                status = "⚠ host key CHANGED for $host — refusing (possible interception)"
                            }
                            else -> main.post { openWith(p, blob) }
                        }
                    }
                }) { Text("Connect") }

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
                            pendingTofu = null
                            openWith(info.port, info.blob)
                        }) { Text("Trust") }
                    },
                    dismissButton = { TextButton(onClick = { pendingTofu = null }) { Text("Cancel") } },
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
