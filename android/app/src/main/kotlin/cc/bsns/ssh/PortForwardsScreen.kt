package cc.bsns.ssh

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cc.bsns.ssh.transport.ForwardSession

/** Connection params for a forwarding session, after host-key verification. */
class ForwardTarget(
    val host: String,
    val port: Int,
    val user: String,
    val pubBlob: ByteArray,
    val signer: Any,
    val expectedHostKey: ByteArray,
)

/**
 * Manage a forwarding connection's local (-L) forwards: each listens on
 * localhost on this device and tunnels through the server to a destination only
 * the server can reach. Mirrors the iOS `PortForwardsView`.
 */
@Composable
fun PortForwardsScreen(session: ForwardSession, onStopAll: () -> Unit, onClose: () -> Unit) {
    var forwards by remember { mutableStateOf(session.list()) }
    var listenPort by remember { mutableStateOf("") }
    var destHost by remember { mutableStateOf("127.0.0.1") }
    var destPort by remember { mutableStateOf("") }
    var status by remember { mutableStateOf<String?>(null) }

    fun add() {
        val lp = listenPort.toIntOrNull()
        val dp = destPort.toIntOrNull()
        if (lp == null || lp !in 1..65535 || destHost.isBlank() || dp == null || dp !in 1..65535) {
            status = "enter a valid local port, host, and destination port"; return
        }
        val err = session.addForward(lp, destHost.trim(), dp)
        if (err == null) { listenPort = ""; destPort = ""; status = null; forwards = session.list() }
        else status = err
    }

    Scaffold { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                Text("Port forwards", fontFamily = FontFamily.Monospace, fontSize = 20.sp)
                TextButton(onClick = onClose) { Text("Done") }
            }
            Text("Listen on a port on this device and tunnel each connection through " +
                "the server to the destination — e.g. reach a database or web UI only the " +
                "server can see. Tunnels keep running until you stop them.",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

            if (forwards.isNotEmpty()) {
                HorizontalDivider()
                Text("Active", fontSize = 13.sp, color = MaterialTheme.colorScheme.primary)
                forwards.forEach { f ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically) {
                        Column {
                            Text("localhost:${f.listenPort}  →  ${f.destHost}:${f.destPort}",
                                fontFamily = FontFamily.Monospace, fontSize = 13.sp)
                            Text(f.error ?: "● listening", fontSize = 12.sp,
                                color = if (f.error != null) MaterialTheme.colorScheme.error
                                        else MaterialTheme.colorScheme.primary)
                        }
                        IconButton(onClick = { session.removeForward(f.listenPort); forwards = session.list() }) {
                            Icon(Icons.Default.Close, "remove forward",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }

            HorizontalDivider()
            Text("New forward", fontSize = 13.sp, color = MaterialTheme.colorScheme.primary)
            OutlinedTextField(listenPort, { listenPort = it }, label = { Text("local port — e.g. 8080") },
                singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(destHost, { destHost = it }, label = { Text("destination host") },
                singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(destPort, { destPort = it }, label = { Text("destination port — e.g. 5432") },
                singleLine = true, modifier = Modifier.fillMaxWidth())
            Button(onClick = { add() }) { Text("Add forward") }

            status?.let { Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.error) }

            HorizontalDivider()
            OutlinedButton(onClick = onStopAll) { Text("Disconnect all tunnels") }
        }
    }
}
