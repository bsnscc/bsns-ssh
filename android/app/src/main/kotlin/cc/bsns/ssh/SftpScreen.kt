package cc.bsns.ssh

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Divider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cc.bsns.ssh.transport.SftpClient
import cc.bsns.ssh.transport.SftpEntry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Everything needed to open an SFTP session — produced by the connect screen
 *  after host-key verification, consumed by [SftpScreen]. */
class SftpTarget(
    val host: String,
    val port: Int,
    val user: String,
    val pubBlob: ByteArray,
    val signer: Any,
    val expectedHostKey: ByteArray,
)

private fun queryName(context: Context, uri: Uri): String? =
    context.contentResolver.query(uri, null, null, null, null)?.use { c ->
        val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        if (i >= 0 && c.moveToFirst()) c.getString(i) else null
    }

private fun byteSize(n: Long): String = when {
    n >= 1_000_000_000 -> "%.1f GB".format(n / 1e9)
    n >= 1_000_000 -> "%.1f MB".format(n / 1e6)
    n >= 1_000 -> "%.1f KB".format(n / 1e3)
    else -> "$n B"
}

/** A minimal SFTP browser over one host: navigate folders, download, upload,
 *  make folders, delete. Mirrors the iOS `SFTPBrowserView`. */
@Composable
fun SftpScreen(target: SftpTarget, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val client = remember {
        SftpClient(target.host, target.port, target.user, target.pubBlob, target.signer, target.expectedHostKey)
    }

    var path by remember { mutableStateOf(".") }
    var stack by remember { mutableStateOf(listOf<String>()) }
    var entries by remember { mutableStateOf<List<SftpEntry>>(emptyList()) }
    var status by remember { mutableStateOf<String?>("connecting…") }
    var connected by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<SftpEntry?>(null) }
    var askNewFolder by remember { mutableStateOf(false) }
    var newFolderName by remember { mutableStateOf("") }
    var pendingDownload by remember { mutableStateOf<SftpEntry?>(null) }

    fun childPath(name: String) = if (path == ".") name else "$path/$name"

    suspend fun reload() {
        withContext(Dispatchers.IO) { runCatching { client.list(path) } }
            .onSuccess { entries = it; status = null }
            .onFailure { status = "couldn't list ${if (path == ".") "~" else path}" }
    }

    val saveDoc = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream"),
    ) { uri ->
        val entry = pendingDownload; pendingDownload = null
        if (uri != null && entry != null) scope.launch {
            status = "downloading ${entry.name}…"
            val ok = withContext(Dispatchers.IO) {
                val bytes = client.download(childPath(entry.name)) ?: return@withContext false
                context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) } != null
            }
            status = if (ok) "saved ${entry.name}" else "download failed"
        }
    }
    val pickUpload = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) scope.launch {
            val name = queryName(context, uri) ?: "upload"
            status = "uploading $name…"
            val ok = withContext(Dispatchers.IO) {
                val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: return@withContext false
                client.upload(childPath(name), bytes)
            }
            if (ok) { status = null; reload() } else status = "upload failed"
        }
    }

    LaunchedEffect(Unit) {
        val ok = withContext(Dispatchers.IO) { runCatching { client.connect() }.getOrDefault(false) }
        if (ok) { connected = true; reload() }
        else status = "couldn't open SFTP (is your key installed?)"
    }
    DisposableEffect(Unit) { onDispose { Thread { client.close() }.start() } }

    fun openEntry(e: SftpEntry) {
        if (!e.isDirectory) { pendingDownload = e; saveDoc.launch(e.name); return }
        stack = stack + path
        path = childPath(e.name)
        scope.launch { reload() }
    }
    fun goUp() {
        val parent = stack.lastOrNull() ?: return
        stack = stack.dropLast(1); path = parent
        scope.launch { reload() }
    }

    Scaffold { pad ->
        Column(Modifier.fillMaxSize().padding(pad).padding(horizontal = 12.dp)) {
            Row(
                Modifier.fillMaxWidth().padding(vertical = 6.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (stack.isEmpty()) TextButton(onClick = onClose) { Text("Done") }
                else TextButton(onClick = { goUp() }) { Text("↑ up") }
                Text(
                    if (path == ".") "~" else path.substringAfterLast('/'),
                    fontFamily = FontFamily.Monospace, fontSize = 15.sp,
                    color = MaterialTheme.colorScheme.primary,
                )
                Row {
                    TextButton(enabled = connected, onClick = { askNewFolder = true }) { Text("+dir") }
                    TextButton(enabled = connected, onClick = { pickUpload.launch("*/*") }) { Text("↑file") }
                }
            }
            status?.let {
                Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(vertical = 4.dp))
            }
            LazyColumn(Modifier.fillMaxSize()) {
                items(entries, key = { it.name }) { e ->
                    Row(
                        Modifier.fillMaxWidth().clickable { openEntry(e) }.padding(vertical = 10.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            (if (e.isDirectory) "📁 " else "📄 ") + e.name,
                            fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                            modifier = Modifier.padding(end = 8.dp),
                        )
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                if (e.isDirectory) "" else byteSize(e.size),
                                fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            TextButton(onClick = { pendingDelete = e }) { Text("✕", fontSize = 12.sp) }
                        }
                    }
                    Divider()
                }
            }
        }
    }

    pendingDelete?.let { e ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete ${e.name}?") },
            text = { Text(if (e.isDirectory) "Deletes this folder on the server." else "Deletes this file on the server.") },
            confirmButton = {
                TextButton(onClick = {
                    val entry = e; pendingDelete = null
                    scope.launch {
                        val ok = withContext(Dispatchers.IO) { client.remove(childPath(entry.name), entry.isDirectory) }
                        if (ok) reload() else status = "couldn't delete ${entry.name}"
                    }
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }

    if (askNewFolder) {
        AlertDialog(
            onDismissRequest = { askNewFolder = false; newFolderName = "" },
            title = { Text("New folder") },
            text = {
                OutlinedTextField(newFolderName, { newFolderName = it }, label = { Text("name") })
            },
            confirmButton = {
                TextButton(onClick = {
                    val name = newFolderName.trim(); askNewFolder = false; newFolderName = ""
                    if (name.isNotEmpty()) scope.launch {
                        val ok = withContext(Dispatchers.IO) { client.mkdir(childPath(name)) }
                        if (ok) reload() else status = "couldn't create $name"
                    }
                }) { Text("Create") }
            },
            dismissButton = { TextButton(onClick = { askNewFolder = false; newFolderName = "" }) { Text("Cancel") } },
        )
    }
}
