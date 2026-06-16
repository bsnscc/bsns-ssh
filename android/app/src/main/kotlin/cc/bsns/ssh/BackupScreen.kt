package cc.bsns.ssh

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Divider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cc.bsns.ssh.core.BadEnvelopeException
import cc.bsns.ssh.core.BadPassphraseException
import cc.bsns.ssh.core.ConfigEnvelope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Encrypted config export / import (backup + cross-device sync). The bundle is
 *  sealed with the shared `ConfigEnvelope` (PBKDF2 + AES-256-GCM) under a
 *  passphrase; private keys are only ever included inside the encrypted bundle. */
@Composable
fun BackupScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var passphrase by remember { mutableStateOf("") }
    var includeKeys by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    var pendingImport by remember { mutableStateOf<JSONObject?>(null) }

    val exportDoc = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/json"),
    ) { uri ->
        if (uri != null) scope.launch {
            status = "exporting…"
            val ok = withContext(Dispatchers.IO) {
                runCatching {
                    val bundle = ConfigBundle.build(context, includeKeys)
                    val sealed = ConfigEnvelope.encrypt(bundle, passphrase)
                    context.contentResolver.openOutputStream(uri)?.use { it.write(sealed) } != null
                }.getOrDefault(false)
            }
            status = if (ok) "exported (encrypted)" else "export failed"
        }
    }

    val importDoc = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) scope.launch {
            status = "decrypting…"
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val sealed = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                        ?: error("unreadable")
                    val plain = if (ConfigEnvelope.isEncrypted(sealed))
                        ConfigEnvelope.decrypt(sealed, passphrase) else sealed
                    ConfigBundle.parse(plain)
                }
            }
            result
                .onSuccess { pendingImport = it; status = null }
                .onFailure {
                    status = when (it) {
                        is BadPassphraseException -> "wrong passphrase"
                        is BadEnvelopeException -> "not a valid backup file"
                        else -> "couldn't read backup"
                    }
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
                Text("Backup & sync", fontFamily = FontFamily.Monospace, fontSize = 20.sp)
                TextButton(onClick = onBack) { Text("Done") }
            }
            Text("Export an encrypted bundle of your hosts, trusted host keys and settings " +
                "to a file, then import it on another device. Choose a strong passphrase.",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

            OutlinedTextField(passphrase, { passphrase = it }, label = { Text("passphrase") },
                visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                Text("Include software private keys", fontSize = 15.sp)
                Switch(checked = includeKeys, onCheckedChange = { includeKeys = it })
            }
            Text("Hardware-backed keys can never be exported. Software keys travel only inside " +
                "this encrypted bundle.", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

            Divider()
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button(enabled = passphrase.isNotEmpty(),
                    onClick = { exportDoc.launch("bsns-ssh-backup.json") }) { Text("Export") }
                OutlinedButton(enabled = passphrase.isNotEmpty(),
                    onClick = { importDoc.launch("*/*") }) { Text("Import") }
            }

            status?.let { Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.primary) }
        }
    }

    pendingImport?.let { o ->
        val s = remember(o) { ConfigBundle.summarize(o) }
        AlertDialog(
            onDismissRequest = { pendingImport = null },
            title = { Text("Import this backup?") },
            text = {
                Text("• ${s.hosts} host(s)\n• ${s.knownHosts} trusted host key(s)\n" +
                    "• ${s.keys} software key(s)\n• settings: ${if (s.hasSettings) "yes" else "no"}\n\n" +
                    "Merges into what's already on this device.")
            },
            confirmButton = {
                TextButton(onClick = {
                    val bundle = o; pendingImport = null
                    scope.launch {
                        withContext(Dispatchers.IO) { runCatching { ConfigBundle.apply(context, bundle) } }
                        status = "imported"
                    }
                }) { Text("Import") }
            },
            dismissButton = { TextButton(onClick = { pendingImport = null }) { Text("Cancel") } },
        )
    }
}
