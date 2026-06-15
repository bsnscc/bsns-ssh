package cc.bsns.ssh

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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

    Scaffold { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("bsns.\$_", fontFamily = FontFamily.Monospace, fontSize = 22.sp)
            Text("Connect over SSH — your key stays in the Keystore.", fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant)

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
                }) { Text("Install my key") }
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

// Strip CSI/OSC/CR so the plain-text view is legible; a real VT widget is next.
private val ANSI = Regex("\\[[0-9;?]*[ -/]*[@-~]|\\][^]*(?:|\\\\)|\r")
private fun stripAnsi(s: String) = s.replace(ANSI, "")

@Composable
fun TerminalScreen(session: SshSession, onDisconnect: () -> Unit) {
    var output by remember { mutableStateOf("") }
    var input by remember { mutableStateOf("") }
    val scroll = rememberScrollState()

    LaunchedEffect(session) {
        session.onOutput = { bytes -> main.post { output += stripAnsi(String(bytes, Charsets.UTF_8)) } }
        session.onClosed = { main.post { output += "\n[disconnected]\n" } }
    }
    LaunchedEffect(output) { scroll.scrollTo(scroll.maxValue) }

    Scaffold { pad ->
        Column(Modifier.fillMaxSize().padding(pad).padding(8.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("bsns.\$_", fontFamily = FontFamily.Monospace, fontSize = 16.sp)
                OutlinedButton(onClick = onDisconnect) { Text("Disconnect") }
            }
            Text(
                output,
                modifier = Modifier.weight(1f).fillMaxWidth().verticalScroll(scroll).padding(top = 6.dp),
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Row(Modifier.fillMaxWidth().padding(top = 8.dp)) {
                OutlinedTextField(input, { input = it }, modifier = Modifier.weight(1f), label = { Text("command") })
                Button(onClick = { session.write((input + "\n").toByteArray()); input = "" },
                    modifier = Modifier.padding(start = 8.dp)) { Text("Send") }
            }
        }
    }
}
