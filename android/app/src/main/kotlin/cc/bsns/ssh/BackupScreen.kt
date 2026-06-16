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
    var pendingImport by remember { mutableStateOf<PendingImport?>(null) }
    val syncStore = remember { SyncStore(context) }
    var syncOn by remember { mutableStateOf(syncStore.enabled) }

    // Pick a sync folder from any Files provider; persist access + the passphrase.
    val pickFolder = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) {
            if (passphrase.isEmpty()) { status = "enter a passphrase first, then choose the folder"; return@rememberLauncherForActivityResult }
            context.contentResolver.takePersistableUriPermission(
                uri,
                android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            syncStore.configure(uri.toString(), passphrase)
            syncOn = true
            scope.launch {
                status = "syncing…"
                // PULL + merge first so an existing bundle from another device is never
                // overwritten before we've taken its contents; then push the union.
                withContext(Dispatchers.IO) { ConfigSync.pull(context); ConfigSync.push(context) }
                status = "auto-sync on"
            }
        }
    }

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
                    val encrypted = ConfigEnvelope.isEncrypted(sealed)
                    val plain = if (encrypted) ConfigEnvelope.decrypt(sealed, passphrase) else sealed
                    PendingImport(ConfigBundle.parse(plain), encrypted)
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

            Divider()
            Text("Auto-sync", fontFamily = FontFamily.Monospace, fontSize = 16.sp)
            Text("Keep your hosts, keys, snippets and settings in sync across devices through " +
                "a folder you control (iCloud Drive, Drive, Dropbox, local…). The provider only " +
                "ever sees the encrypted bundle — no account, no server of ours. Syncs on open and " +
                "when you background the app.", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (syncOn) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(onClick = {
                        scope.launch {
                            status = "syncing…"
                            status = withContext(Dispatchers.IO) {
                                ConfigSync.pull(context); ConfigSync.push(context)
                            }
                        }
                    }) { Text("Sync now") }
                    OutlinedButton(onClick = { syncStore.clear(); syncOn = false; status = "auto-sync off" }) {
                        Text("Turn off")
                    }
                }
            } else {
                OutlinedButton(enabled = passphrase.isNotEmpty(), onClick = { pickFolder.launch(null) }) {
                    Text("Choose a sync folder")
                }
            }

            status?.let { Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.primary) }
        }
    }

    pendingImport?.let { o ->
        val s = remember(o) { ConfigBundle.summarize(o.bundle) }
        var impHosts by remember(o) { mutableStateOf(s.hosts > 0) }       // low-risk → default on
        var impSettings by remember(o) { mutableStateOf(s.hasSettings) }  // low-risk → default on
        var impKnown by remember(o) { mutableStateOf(false) }             // explicit opt-in
        var impKeys by remember(o) { mutableStateOf(false) }              // explicit opt-in
        var impSnippets by remember(o) { mutableStateOf(false) }          // executable config → opt-in
        val keysAllowed = o.encrypted && s.keys > 0                       // never from a plaintext bundle
        AlertDialog(
            onDismissRequest = { pendingImport = null },
            title = { Text("Import this backup?") },
            text = {
                Column {
                    Text("Choose what to merge into this device:", fontSize = 13.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (s.hosts > 0) ImportToggle("${s.hosts} saved host(s)", impHosts) { impHosts = it }
                    if (s.hasSettings) ImportToggle("Settings", impSettings) { impSettings = it }
                    if (s.knownHosts > 0) ImportToggle("${s.knownHosts} trusted host key(s)", impKnown) { impKnown = it }
                    if (s.keys > 0) ImportToggle("${s.keys} software private key(s)",
                        impKeys && keysAllowed, enabled = keysAllowed) { impKeys = it }
                    if (s.keys > 0 && !keysAllowed) Text(
                        "Private keys are only imported from an encrypted backup.",
                        fontSize = 11.sp, color = MaterialTheme.colorScheme.error)
                    if (s.snippets > 0) ImportToggle("${s.snippets} snippet(s)", impSnippets) { impSnippets = it }
                    if (s.snippets > 0) Text(
                        "Snippets are commands. Imported snippets won't run on connect until you " +
                            "enable that yourself" + (if (s.runOnConnect > 0) " (${s.runOnConnect} were marked run-on-connect)." else "."),
                        fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            },
            confirmButton = {
                val anySelected = impHosts || impSettings || impKnown || (impKeys && keysAllowed) || impSnippets
                TextButton(enabled = anySelected, onClick = {
                    val bundle = o.bundle
                    val sel = ConfigBundle.Selection(impHosts, impKnown, impSettings, impKeys && keysAllowed, impSnippets)
                    pendingImport = null
                    scope.launch {
                        val result = withContext(Dispatchers.IO) {
                            runCatching { ConfigBundle.apply(context, bundle, sel) }
                        }
                        status = result.fold(
                            onSuccess = { if (it.isEmpty) "nothing to import" else it.summary },
                            onFailure = { "import failed — the backup may be damaged" },
                        )
                    }
                }) { Text("Import") }
            },
            dismissButton = { TextButton(onClick = { pendingImport = null }) { Text("Cancel") } },
        )
    }
}

/** A parsed bundle awaiting the import review, plus whether it came encrypted. */
private class PendingImport(val bundle: org.json.JSONObject, val encrypted: Boolean)

@Composable
private fun ImportToggle(label: String, value: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 14.sp,
            color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
        Switch(checked = value, onCheckedChange = onChange, enabled = enabled)
    }
}
