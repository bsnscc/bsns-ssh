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
import androidx.compose.material3.Divider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cc.bsns.ssh.core.KeyImportException
import cc.bsns.ssh.core.KnownHostsParser
import cc.bsns.ssh.core.OpenSshPrivateKey
import cc.bsns.ssh.core.SshConfigHost
import cc.bsns.ssh.core.SshConfigParser
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** A parsed `ssh_config` awaiting confirmation — shown in a preview dialog. */
private class PendingHosts(val hosts: List<SshConfigHost>)

/**
 * Migrate an existing OpenSSH setup: pick a `config`, `known_hosts`, or private
 * key file (any Files provider) and merge it in. Everything is additive and
 * reviewed before it lands; nothing phones home. Parsing lives in `:core`.
 */
@Composable
fun ImportConfigScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var status by remember { mutableStateOf<String?>(null) }
    var pendingHosts by remember { mutableStateOf<PendingHosts?>(null) }

    fun readText(uri: android.net.Uri?): String? =
        uri?.let { context.contentResolver.openInputStream(it)?.use { s -> s.readBytes().toString(Charsets.UTF_8) } }

    // ssh_config → preview the discovered hosts, then merge on confirm.
    val pickConfig = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        scope.launch {
            val hosts = withContext(Dispatchers.IO) {
                runCatching { SshConfigParser.parse(readText(uri) ?: "") }.getOrDefault(emptyList())
            }
            if (hosts.isEmpty()) status = "no hosts found in that file"
            else { pendingHosts = PendingHosts(hosts); status = null }
        }
    }

    // known_hosts → trust each recovered entry (hashed lines can't be imported).
    val pickKnown = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        scope.launch {
            val n = withContext(Dispatchers.IO) {
                runCatching {
                    val store = KnownHostsStore(context)
                    KnownHostsParser.parse(readText(uri) ?: "").onEach { store.trustRaw(it.id, it.blob) }.size
                }.getOrDefault(0)
            }
            status = if (n > 0) "trusted $n host key(s)" else "no usable host keys (hashed entries can't be imported)"
        }
    }

    // A private key file → import as a software key, or explain why it can't.
    val pickKey = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        scope.launch {
            status = withContext(Dispatchers.IO) {
                try {
                    val k = OpenSshPrivateKey.parse(readText(uri) ?: "")
                    KeyManager(context).importSoftware(k.algorithm.wireName, k.material, k.comment)
                    "imported a ${k.algorithm.wireName.removePrefix("ssh-")} key"
                } catch (e: KeyImportException) {
                    e.message ?: "couldn't import that key"
                } catch (e: Exception) {
                    "couldn't read that file"
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
                Text("Import from OpenSSH", fontFamily = FontFamily.Monospace, fontSize = 20.sp)
                TextButton(onClick = onBack) { Text("Done") }
            }
            Text("Bring over an existing setup. Pick the files from ~/.ssh — nothing leaves " +
                "your device, and everything is added alongside what you already have.",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

            Divider()
            OutlinedButton(onClick = { pickConfig.launch("*/*") }, modifier = Modifier.fillMaxWidth()) {
                Text("Import an ssh config")
            }
            Text("Reads Host blocks (HostName, Port, User, ProxyJump) into your saved hosts.",
                fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

            OutlinedButton(onClick = { pickKnown.launch("*/*") }, modifier = Modifier.fillMaxWidth()) {
                Text("Import known_hosts")
            }
            Text("Trusts the host keys you already accepted. Hashed (anonymized) entries " +
                "can't be recovered and are skipped.",
                fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

            OutlinedButton(onClick = { pickKey.launch("*/*") }, modifier = Modifier.fillMaxWidth()) {
                Text("Import a private key")
            }
            Text("Unencrypted OpenSSH ed25519 / ecdsa-p256 keys. Decrypt a passphrase-protected " +
                "key first (ssh-keygen -p), or generate a new device key instead.",
                fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

            status?.let { Divider(); Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.primary) }
        }
    }

    pendingHosts?.let { p ->
        AlertDialog(
            onDismissRequest = { pendingHosts = null },
            title = { Text("Import ${p.hosts.size} host(s)?") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    p.hosts.forEach { h ->
                        val who = h.user?.let { "$it@" } ?: ""
                        val port = if (h.port == 22) "" else ":${h.port}"
                        val via = h.proxyJump?.let { "  via $it" } ?: ""
                        Text("$who${h.hostName}$port$via", fontFamily = FontFamily.Monospace, fontSize = 13.sp)
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val hosts = p.hosts
                    pendingHosts = null
                    scope.launch {
                        val n = withContext(Dispatchers.IO) {
                            val store = HostStore(context)
                            var added = 0
                            hosts.forEach { h ->
                                store.add(SavedHost(h.hostName, h.port, h.user ?: "", h.proxyJump))
                                added++
                            }
                            added
                        }
                        status = "imported $n host(s)"
                    }
                }) { Text("Import") }
            },
            dismissButton = { TextButton(onClick = { pendingHosts = null }) { Text("Cancel") } },
        )
    }
}
