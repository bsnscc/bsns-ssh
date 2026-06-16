package cc.bsns.ssh

import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
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
    // The app's identity: a non-extractable Keystore key (TEE; StrongBox on device).
    val signer = remember { KeystoreSigner("bsns-app-key") }
    var session by remember { mutableStateOf<SshSession?>(null) }

    val active = session
    if (active == null) {
        ConnectScreen(signer) { session = it }
    } else {
        TerminalScreen(active) { active.close(); session = null }
    }
}

@Composable
fun ConnectScreen(signer: KeystoreSigner, onConnected: (SshSession) -> Unit) {
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
                    busy = true; status = "connecting…"
                    thread {
                        val p = port.toIntOrNull() ?: 22
                        val s = SshSession(host, p, user, signer.publicKeyBlob, signer)
                        if (s.open(80, 24)) main.post { busy = false; onConnected(s) }
                        else main.post { busy = false; status = "couldn't open the session (is your key installed?)" }
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
        }
    }
}


/**
 * Real VT terminal: a vendored Termux TerminalView, SSH-backed via our forked
 * TerminalSession. The view renders the screen (cursor, colors, vim/htop) and
 * handles keyboard/IME input directly — type and see at once, no command box.
 */
@Composable
fun TerminalScreen(session: SshSession, onDisconnect: () -> Unit) {
    val context = LocalContext.current
    val terminalView = remember(session) {
        TerminalView(context, null).apply {
            setTextSize((14 * resources.displayMetrics.scaledDensity).toInt())
            setTypeface(Typeface.MONOSPACE)
            keepScreenOn = true
            isFocusableInTouchMode = true
        }
    }

    DisposableEffect(session) {
        val io = object : TerminalSession.ExternalIo {
            override fun write(data: ByteArray, offset: Int, count: Int) =
                session.write(data.copyOfRange(offset, offset + count))
            override fun onResize(columns: Int, rows: Int) = session.resize(columns, rows)
        }
        val termSession = TerminalSession(5000, BsnsSessionClient { terminalView.onScreenUpdated() }, io)
        terminalView.setTerminalViewClient(BsnsViewClient(view = { terminalView }, onEmulatorReady = {
            // Emulator is ready — start feeding remote output (the SshSession
            // buffered anything that arrived before now).
            session.onOutput = { bytes -> main.post { termSession.appendToEmulator(bytes, bytes.size) } }
        }))
        terminalView.attachSession(termSession)
        terminalView.requestFocus()
        onDispose { session.onOutput = null }
    }

    Scaffold { pad ->
        Column(Modifier.fillMaxSize().padding(pad).imePadding()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("bsns.\$_", fontFamily = FontFamily.Monospace, fontSize = 16.sp)
                OutlinedButton(onClick = onDisconnect) { Text("Disconnect") }
            }
            AndroidView(factory = { terminalView }, modifier = Modifier.weight(1f).fillMaxWidth())
            KeyBar { session.write(it) }
        }
    }
}

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
