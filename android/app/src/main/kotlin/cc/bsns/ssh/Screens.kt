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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cc.bsns.ssh.core.KeyAlgorithm

fun copyToClipboard(context: Context, label: String, text: String) {
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
    var fidoPin by remember { mutableStateOf("") }
    var fidoStatus by remember { mutableStateOf<String?>(null) }
    var protectedStatus by remember { mutableStateOf<String?>(null) }
    val mainHandler = remember { android.os.Handler(android.os.Looper.getMainLooper()) }

    fun refresh() { keys = keyManager.keys() }

    val softwareTag = Color(0xFFE0A45A)   // amber for exportable software keys (matches iOS)
    Scaffold { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(Spacing.screen).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(Spacing.section),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                Text("Keys", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                TextButton(onClick = onBack) { Text("Done") }
            }

            Section(
                title = "Keys in the agent",
                footer = "Your device key stays in the Android Keystore and can't be exported. Software keys are encrypted at rest. Each key shows how it's backed.",
            ) {
                if (keys.isEmpty()) {
                    Text("No keys yet — generate one below.", fontSize = 14.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 10.dp))
                }
                keys.forEachIndexed { i, k ->
                    if (i > 0) RowDivider()
                    Column(Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically) {
                            Text(k.label, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                                color = MaterialTheme.colorScheme.primary)
                            CapsuleTag(
                                when {
                                    k.fido -> "FIDO2"
                                    k.yubiKey -> "Smart card"
                                    k.protectedDeviceKey -> "Biometric"
                                    k.hardware -> "Hardware"
                                    else -> "Software · exportable"
                                },
                                if (k.hardware) Brand.accent else softwareTag,
                            )
                        }
                        Text(k.fingerprint, fontFamily = FontFamily.Monospace, fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 4.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(top = 2.dp)) {
                            TextButton(onClick = { copyToClipboard(context, "authorized_keys", k.authLine) }) {
                                Text("Copy public key", fontSize = 13.sp)
                            }
                            if (k.yubiKey) {
                                TextButton(onClick = { keyManager.forgetYubiKey(k.id); refresh() }) { Text("Forget", fontSize = 13.sp) }
                            } else if (k.fido) {
                                TextButton(onClick = { keyManager.forgetFido(k.id); refresh() }) { Text("Forget", fontSize = 13.sp) }
                            } else if (k.protectedDeviceKey) {
                                TextButton(onClick = { keyManager.removeProtectedDeviceKey(); refresh() }) { Text("Remove", fontSize = 13.sp) }
                            } else if (!k.builtIn) {
                                TextButton(onClick = { confirmDelete = k }) { Text("Delete", fontSize = 13.sp) }
                            }
                        }
                    }
                }
            }

            Section(
                title = "Generate a software key",
                footer = "Use RSA only for older gear (some network equipment) that can't accept ed25519 or ecdsa keys.",
            ) {
                Row(Modifier.padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    val gen = @Composable { label: String, algo: KeyAlgorithm ->
                        OutlinedButton(
                            onClick = { keyManager.generateSoftware(algo); refresh() },
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp),
                        ) { Text(label, maxLines = 1) }
                    }
                    gen("+ ed25519", KeyAlgorithm.ED25519)
                    gen("+ ecdsa", KeyAlgorithm.ECDSA_P256)
                    gen("+ rsa", KeyAlgorithm.RSA)
                }
            }

            // Opt-in: a separate Keystore key that demands a strong biometric on
            // every signature. Only offered when a strong biometric is enrolled and
            // the key doesn't exist yet; once added it appears above with a
            // "Biometric" tag and a Remove action. The everyday device key is never changed.
            if (strongBiometricAvailable(context) && !keys.any { it.protectedDeviceKey }) {
                Section(
                    title = "Add a biometric-protected device key",
                    footer = "A second non-extractable device key that requires a strong (class-3) " +
                        "biometric — fingerprint, face, or iris, depending on your device — for every " +
                        "signature, so a connection can't be made while the phone is unlocked but " +
                        "unattended. It's a new key with its own public key: add it to your servers " +
                        "and pick it per host. Your everyday device key is left as is.",
                ) {
                    Column(Modifier.padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = {
                            protectedStatus = "generating…"
                            thread {
                                val result = runCatching { keyManager.addProtectedDeviceKey() }
                                mainHandler.post {
                                    result.onSuccess { protectedStatus = "added"; refresh() }
                                        .onFailure { protectedStatus = it.message ?: "couldn't create the key" }
                                }
                            }
                        }) { Text("Add protected key") }
                        protectedStatus?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.primary) }
                    }
                }
            }

            Section(
                title = "Add a FIDO2 security key",
                footer = "Create a portable SSH security-key credential on your YubiKey, or import one " +
                    "already on the key. The private key never leaves the token. One authorized_keys " +
                    "line can work on Android and iOS when the phone can talk to the key and the server " +
                    "supports OpenSSH FIDO2.",
            ) {
                Column(Modifier.padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(fidoPin, { fidoPin = it }, label = { Text("Security-key PIN") },
                        visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(enabled = fidoPin.isNotEmpty(), onClick = {
                            val pin = fidoPin
                            fidoStatus = "creating…"
                            thread {
                                val result = runCatching { keyManager.enrollFido(pin) }
                                mainHandler.post {
                                    result.onSuccess { fidoPin = ""; fidoStatus = "created"; refresh() }
                                        .onFailure { fidoStatus = it.message ?: "couldn't create the security-key credential" }
                                }
                            }
                        }) { Text("Create on key") }
                        OutlinedButton(enabled = fidoPin.isNotEmpty(), onClick = {
                            val pin = fidoPin
                            fidoStatus = "importing…"
                            thread {
                                val result = runCatching { keyManager.importFido(pin) }
                                mainHandler.post {
                                    result.onSuccess { count ->
                                        fidoPin = ""
                                        fidoStatus = if (count == 0) "already added" else "imported"
                                        refresh()
                                    }.onFailure { fidoStatus = it.message ?: "couldn't import the security key" }
                                }
                            }
                        }) { Text("Import from key") }
                    }
                    fidoStatus?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.primary) }
                }
            }

            Section(
                title = "Add a smart card (PIV)",
                footer = "Slot 9A, P-256 over NFC or USB-C — the private key never leaves the card. " +
                    "Produces a plain ecdsa-sha2-nistp256 key every SSH server accepts, and the same " +
                    "card works on Android and iOS with a single authorized_keys line.",
            ) {
                Column(Modifier.padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(yubiPin, { yubiPin = it }, label = { Text("PIV PIN") },
                        visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
                    OutlinedButton(enabled = yubiPin.isNotEmpty(), onClick = {
                        val pin = yubiPin
                        yubiStatus = "enrolling…"
                        thread {
                            val result = runCatching { keyManager.enrollYubiKey(pin) }
                            mainHandler.post {
                                result.onSuccess { yubiPin = ""; yubiStatus = "enrolled"; refresh() }
                                    .onFailure { yubiStatus = it.message ?: "couldn't read the smart card" }
                            }
                        }
                    }) { Text("Enroll smart card") }
                    yubiStatus?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.primary) }
                }
            }
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
    var confirmForget by remember { mutableStateOf<KnownHostEntry?>(null) }

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
                RowDivider()
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.padding(end = 8.dp)) {
                        Text(h.id, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                            color = MaterialTheme.colorScheme.primary)
                        SelectionContainer {
                            Text(h.fingerprint, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
                        }
                    }
                    TextButton(onClick = { confirmForget = h }) { Text("Forget") }
                }
            }
        }
    }

    confirmForget?.let { h ->
        AlertDialog(
            onDismissRequest = { confirmForget = null },
            title = { Text("Forget host key?") },
            text = { Text("Forget the trusted host key for ${h.id}? " +
                "You'll be asked to verify it again next time you connect.") },
            confirmButton = {
                TextButton(onClick = {
                    store.forgetId(h.id); hosts = store.all(); confirmForget = null
                }) { Text("Forget") }
            },
            dismissButton = { TextButton(onClick = { confirmForget = null }) { Text("Cancel") } },
        )
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
