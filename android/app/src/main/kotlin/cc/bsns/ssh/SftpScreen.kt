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
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.InsertDriveFile
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.HorizontalDivider
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
    var canRetry by remember { mutableStateOf(false) }   // true when the last status is a retryable failure
    var pendingDelete by remember { mutableStateOf<SftpEntry?>(null) }
    var askNewFolder by remember { mutableStateOf(false) }
    var newFolderName by remember { mutableStateOf("") }
    var pendingDownload by remember { mutableStateOf<SftpEntry?>(null) }

    fun childPath(name: String) = if (path == ".") name else "$path/$name"

    suspend fun reload() {
        withContext(Dispatchers.IO) { runCatching { client.list(path) } }
            .onSuccess { entries = it; status = null; canRetry = false }
            .onFailure { status = "couldn't list ${if (path == ".") "~" else path}"; canRetry = true }
    }

    suspend fun connectThenLoad() {
        status = "connecting…"; canRetry = false
        val ok = withContext(Dispatchers.IO) { runCatching { client.connect() }.getOrDefault(false) }
        if (ok) { connected = true; reload() }
        else { status = "couldn't open SFTP (is your key installed?)"; canRetry = true }
    }

    val saveDoc = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream"),
    ) { uri ->
        val entry = pendingDownload; pendingDownload = null
        if (uri != null && entry != null) scope.launch {
            status = "downloading ${entry.name}…"
            // Stream the remote file straight into the SAF output stream — no
            // whole-file buffer, so a multi-GB file won't OOM.
            val ok = withContext(Dispatchers.IO) {
                context.contentResolver.openOutputStream(uri)?.use {
                    client.downloadTo(childPath(entry.name), it)
                } ?: false
            }
            status = if (ok) "saved ${entry.name}" else "download failed"
        }
    }
    val pickUpload = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) scope.launch {
            val name = queryName(context, uri) ?: "upload"
            status = "uploading $name…"
            val ok = withContext(Dispatchers.IO) {
                context.contentResolver.openInputStream(uri)?.use {
                    client.uploadFrom(childPath(name), it)
                } ?: false
            }
            if (ok) { status = null; reload() } else status = "upload failed"
        }
    }

    LaunchedEffect(Unit) { connectThenLoad() }
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
                else IconButton(onClick = { goUp() }) { Icon(Icons.Default.ArrowUpward, "up") }
                Text(
                    if (path == ".") "~" else path.substringAfterLast('/'),
                    fontFamily = FontFamily.Monospace, fontSize = 15.sp,
                    color = MaterialTheme.colorScheme.primary,
                )
                Row {
                    IconButton(enabled = connected, onClick = { askNewFolder = true }) {
                        Icon(Icons.Default.CreateNewFolder, "new folder")
                    }
                    IconButton(enabled = connected, onClick = { pickUpload.launch("*/*") }) {
                        Icon(Icons.Default.UploadFile, "upload a file")
                    }
                }
            }
            status?.let {
                Row(Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.primary)
                    if (canRetry) {
                        TextButton(onClick = {
                            scope.launch { if (connected) reload() else connectThenLoad() }
                        }) { Text("Retry", fontSize = 13.sp) }
                    }
                }
            }
            LazyColumn(Modifier.fillMaxSize()) {
                items(entries, key = { it.name }) { e ->
                    Row(
                        Modifier.fillMaxWidth().clickable { openEntry(e) }.padding(vertical = 8.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                if (e.isDirectory) Icons.Default.Folder else Icons.Default.InsertDriveFile,
                                contentDescription = null,
                                tint = if (e.isDirectory) MaterialTheme.colorScheme.primary
                                       else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(end = 10.dp).size(20.dp),
                            )
                            Text(e.name, fontFamily = FontFamily.Monospace, fontSize = 14.sp)
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                if (e.isDirectory) "" else byteSize(e.size),
                                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            IconButton(onClick = { pendingDelete = e }) {
                                Icon(Icons.Default.DeleteOutline, "delete",
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                    HorizontalDivider()
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
                        if (ok) reload()
                        else {
                            // The native remove only reports a bare boolean, so to give
                            // a useful message on a directory failure we re-list it: a
                            // non-empty folder is the common cause servers reject rmdir for.
                            val nonEmpty = entry.isDirectory && withContext(Dispatchers.IO) {
                                runCatching { client.list(childPath(entry.name)).isNotEmpty() }.getOrDefault(false)
                            }
                            status = if (nonEmpty) "couldn't delete ${entry.name} — the folder isn't empty"
                                     else "couldn't delete ${entry.name}"
                            canRetry = false
                        }
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
