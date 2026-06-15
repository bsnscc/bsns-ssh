package cc.bsns.ssh

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
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

/**
 * v0 terminal screen for the Android app: opens a session via a non-extractable
 * Keystore key and streams shell output. Output is ANSI-stripped for legibility
 * — a real VT terminal widget (Termux terminal-view, GPLv3-compatible) is the
 * next step. The demo target is hardcoded; a connect form replaces it later.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme(colorScheme = darkColorScheme()) { TerminalScreen() } }
    }
}

private val ANSI = Regex("\\[[0-9;?]*[ -/]*[@-~]|][^]*(|\\\\)|\r")
private fun stripAnsi(s: String) = s.replace(ANSI, "")

@Composable
fun TerminalScreen() {
    var output by remember { mutableStateOf("bsns.\$_  —  connecting to the demo host…\n\n") }
    var session by remember { mutableStateOf<SshSession?>(null) }
    var input by remember { mutableStateOf("") }
    val scroll = rememberScrollState()
    val main = remember { Handler(Looper.getMainLooper()) }

    LaunchedEffect(Unit) {
        thread(name = "connect") {
            try {
                val signer = KeystoreSigner("bsns-app-key")
                val line = "ecdsa-sha2-nistp256 " +
                    Base64.getEncoder().encodeToString(signer.publicKeyBlob) + " bsns"
                SshBridge().nativeInstallKey("10.0.2.2", 2222, "tester", "testpw", line)
                val s = SshSession("10.0.2.2", 2222, "tester", signer.publicKeyBlob, signer)
                s.onOutput = { bytes ->
                    val txt = stripAnsi(String(bytes, Charsets.UTF_8))
                    main.post { output += txt }
                }
                s.onClosed = { main.post { output += "\n[disconnected]\n" } }
                if (s.open(80, 24)) main.post { session = s }
                else main.post { output += "[failed to open session]\n" }
            } catch (e: Exception) {
                main.post { output += "[error: ${e.message}]\n" }
            }
        }
    }

    LaunchedEffect(output) { scroll.scrollTo(scroll.maxValue) }

    Scaffold { pad ->
        Column(Modifier.fillMaxSize().padding(pad).padding(8.dp)) {
            Text(
                output,
                modifier = Modifier.weight(1f).fillMaxWidth().verticalScroll(scroll),
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Row(Modifier.fillMaxWidth().padding(top = 8.dp)) {
                OutlinedTextField(
                    value = input,
                    onValueChange = { input = it },
                    modifier = Modifier.weight(1f),
                    label = { Text("command") },
                    enabled = session != null,
                )
                Button(
                    onClick = {
                        session?.write((input + "\n").toByteArray())
                        input = ""
                    },
                    enabled = session != null,
                    modifier = Modifier.padding(start = 8.dp),
                ) { Text("Send") }
            }
        }
    }
}
