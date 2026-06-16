package cc.bsns.ssh

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Divider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.text.input.PasswordVisualTransformation
import kotlin.concurrent.thread
import androidx.compose.runtime.Composable
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
import cc.bsns.ssh.core.KeyAlgorithm

private fun copyToClipboard(context: Context, label: String, text: String) {
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.setPrimaryClip(ClipData.newPlainText(label, text))
    Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
}

/** Key management: the hardware Keystore key plus generated software keys. */
@Composable
fun KeysScreen(keyManager: KeyManager, onBack: () -> Unit) {
    val context = LocalContext.current
    var keys by remember { mutableStateOf(keyManager.keys()) }
    var confirmDelete by remember { mutableStateOf<AppKey?>(null) }
    var yubiPin by remember { mutableStateOf("") }
    var yubiStatus by remember { mutableStateOf<String?>(null) }
    val mainHandler = remember { android.os.Handler(android.os.Looper.getMainLooper()) }

    fun refresh() { keys = keyManager.keys() }

    Scaffold { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                Text("Keys", fontFamily = FontFamily.Monospace, fontSize = 20.sp)
                TextButton(onClick = onBack) { Text("Done") }
            }
            Text("Your hardware key never leaves the Keystore. Software keys are encrypted at rest.",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

            keys.forEach { k ->
                Divider()
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(k.label, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                        color = MaterialTheme.colorScheme.primary)
                    Text(if (k.yubiKey) "yubikey" else if (k.hardware) "hardware" else "software",
                        fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(k.fingerprint, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { copyToClipboard(context, "authorized_keys", k.authLine) }) {
                        Text("Copy public key")
                    }
                    if (k.yubiKey) {
                        OutlinedButton(onClick = { keyManager.forgetYubiKey(k.id); refresh() }) { Text("Forget") }
                    } else if (!k.hardware) {
                        OutlinedButton(onClick = { confirmDelete = k }) { Text("Delete") }
                    }
                }
            }

            Divider()
            Text("Generate a software key", fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { keyManager.generateSoftware(KeyAlgorithm.ED25519); refresh() }) {
                    Text("+ ed25519")
                }
                OutlinedButton(onClick = { keyManager.generateSoftware(KeyAlgorithm.ECDSA_P256); refresh() }) {
                    Text("+ ecdsa p256")
                }
            }

            Divider()
            Text("Add a YubiKey (PIV slot 9A, P-256)", fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp))
            Text("Reads (or generates) the key in the authentication slot. The private key never " +
                "leaves the token — it signs over NFC or USB-C.", fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedTextField(yubiPin, { yubiPin = it }, label = { Text("YubiKey PIN") },
                visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
            OutlinedButton(enabled = yubiPin.isNotEmpty(), onClick = {
                val pin = yubiPin
                yubiStatus = "enrolling…"
                thread {
                    val result = runCatching { keyManager.enrollYubiKey(pin) }
                    mainHandler.post {
                        result.onSuccess { yubiPin = ""; yubiStatus = "enrolled"; refresh() }
                            .onFailure { yubiStatus = it.message ?: "couldn't read the YubiKey" }
                    }
                }
            }) { Text("Enroll YubiKey") }
            yubiStatus?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.primary) }
        }
    }

    confirmDelete?.let { k ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text("Delete key?") },
            text = { Text("This software key will be erased from this device permanently.\n\n${k.fingerprint}") },
            confirmButton = {
                TextButton(onClick = {
                    keyManager.deleteSoftware(k.id); confirmDelete = null; refresh()
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("Cancel") } },
        )
    }
}

/** Known-hosts manager: the TOFU host keys we've trusted, with a forget action. */
@Composable
fun KnownHostsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val store = remember { KnownHostsStore(context) }
    var hosts by remember { mutableStateOf(store.all()) }

    Scaffold { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                Text("Known hosts", fontFamily = FontFamily.Monospace, fontSize = 20.sp)
                TextButton(onClick = onBack) { Text("Done") }
            }
            Text("Host keys you've trusted on first connection. Forget one to be re-prompted.",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

            if (hosts.isEmpty()) {
                Text("No trusted hosts yet.", fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            hosts.forEach { h ->
                Divider()
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.padding(end = 8.dp)) {
                        Text(h.id, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                            color = MaterialTheme.colorScheme.primary)
                        SelectionContainer {
                            Text(h.fingerprint, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
                        }
                    }
                    TextButton(onClick = { store.forgetId(h.id); hosts = store.all() }) { Text("Forget") }
                }
            }
        }
    }
}

/** Compact selector for which key authenticates the next connection. */
@Composable
fun KeyPicker(keys: List<AppKey>, selectedId: String, onSelect: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text("Key", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        keys.forEach { k ->
            val sel = k.id == selectedId
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { onSelect(k.id) }) {
                    Text(
                        (if (sel) "● " else "○ ") + k.label,
                        fontFamily = FontFamily.Monospace, fontSize = 13.sp,
                        color = if (sel) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}
