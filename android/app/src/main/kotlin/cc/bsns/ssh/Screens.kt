package cc.bsns.ssh

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.CreditCard
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Fingerprint
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.Usb
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cc.bsns.ssh.core.KeyAlgorithm
import kotlin.concurrent.thread

fun copyToClipboard(context: Context, label: String, text: String) {
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.setPrimaryClip(ClipData.newPlainText(label, text))
    Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
}

/** Which hardware token a PIN dialog is enrolling. */
private enum class TokenKind { Fido, Piv }

/** Key management: the keys in the agent, then ways to add one — device-backed
 *  first, then hardware tokens, then exportable software keys. The long
 *  explanations sit behind "About key types" so the screen stays scannable. */
@Composable
fun KeysScreen(keyManager: KeyManager, onKeysChanged: () -> Unit) {
    val context = LocalContext.current
    var keys by remember { mutableStateOf(keyManager.keys()) }
    var confirmDelete by remember { mutableStateOf<AppKey?>(null) }
    var tokenDialog by remember { mutableStateOf<TokenKind?>(null) }
    var showAbout by remember { mutableStateOf(false) }
    // One status line for whichever add/enroll ran last.
    var status by remember { mutableStateOf<String?>(null) }
    val mainHandler = remember { android.os.Handler(android.os.Looper.getMainLooper()) }

    fun refresh() { keys = keyManager.keys(); onKeysChanged() }

    // Run a blocking key operation off the main thread, then report + refresh.
    fun runKeyOp(working: String, op: () -> String) {
        status = working
        thread {
            val result = runCatching(op)
            mainHandler.post {
                status = result.getOrElse { it.message ?: "that didn't work" }
                refresh()
            }
        }
    }

    val softwareTag = Color(0xFFE0A45A)   // amber for exportable software keys (matches iOS)
    Scaffold { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(horizontal = Spacing.screen).verticalScroll(rememberScrollState())
                .padding(bottom = Spacing.screen),
            verticalArrangement = Arrangement.spacedBy(Spacing.section),
        ) {
            ScreenTitle("Keys")

            Section(
                title = "Keys in the agent",
                footer = "Device keys live in the Android Keystore and can't be exported. Software keys are encrypted at rest.",
            ) {
                keys.forEachIndexed { i, k ->
                    if (i > 0) RowDivider()
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = Spacing.rowMinHeight).padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            when {
                                k.fido || k.yubiKey -> Icons.Outlined.Usb
                                k.protectedDeviceKey -> Icons.Outlined.Fingerprint
                                k.hardware -> Icons.Outlined.Memory
                                else -> Icons.Outlined.Key
                            },
                            contentDescription = null,
                            tint = if (k.hardware) Brand.accent else softwareTag,
                            modifier = Modifier.size(22.dp),
                        )
                        Column(Modifier.weight(1f).padding(horizontal = 14.dp)) {
                            Text(k.label, fontSize = 15.sp)
                            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 3.dp)) {
                                CapsuleTag(
                                    when {
                                        k.fido -> "FIDO2"
                                        k.yubiKey -> "Smart card"
                                        k.protectedDeviceKey -> "Biometric"
                                        k.hardware -> "Hardware"
                                        else -> "Exportable"
                                    },
                                    if (k.hardware) Brand.accent else softwareTag,
                                )
                            }
                            Text(k.fingerprint, fontFamily = FontFamily.Monospace, fontSize = 11.sp,
                                maxLines = 1, overflow = TextOverflow.Ellipsis,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(top = 4.dp))
                        }
                        IconButton(onClick = { copyToClipboard(context, "authorized_keys", k.authLine) }) {
                            Icon(Icons.Outlined.ContentCopy, "copy public key for ${k.label}",
                                tint = MaterialTheme.colorScheme.primary)
                        }
                        // The everyday device key can't be removed; everything else can.
                        if (!k.builtIn) {
                            IconButton(onClick = { confirmDelete = k }) {
                                Icon(Icons.Outlined.Delete, "remove ${k.label}",
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }

            status?.let {
                Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(horizontal = 6.dp))
            }

            Section(title = "Add a key") {
                // Opt-in: a second device key that demands a strong biometric on every
                // signature. Offered only with a strong biometric enrolled and none yet.
                if (strongBiometricAvailable(context) && !keys.any { it.protectedDeviceKey }) {
                    ActionRow("Device key with biometric", Icons.Outlined.Fingerprint, detail = "non-exportable") {
                        runKeyOp("generating…") { keyManager.addProtectedDeviceKey(); "Added a biometric device key." }
                    }
                    RowDivider()
                }
                ActionRow("FIDO2 security key", Icons.Outlined.Usb, detail = "NFC · USB-C") { tokenDialog = TokenKind.Fido }
                RowDivider()
                ActionRow("Smart card (PIV)", Icons.Outlined.CreditCard, detail = "NFC · USB-C") { tokenDialog = TokenKind.Piv }
                RowDivider()
                ActionRow("Software key · Ed25519", Icons.Outlined.Add) {
                    runKeyOp("generating…") { keyManager.generateSoftware(KeyAlgorithm.ED25519); "Generated an Ed25519 key." }
                }
                RowDivider()
                ActionRow("Software key · ECDSA P-256", Icons.Outlined.Add) {
                    runKeyOp("generating…") { keyManager.generateSoftware(KeyAlgorithm.ECDSA_P256); "Generated an ECDSA key." }
                }
                RowDivider()
                ActionRow("Software key · RSA", Icons.Outlined.Add, detail = "older servers") {
                    runKeyOp("generating…") { keyManager.generateSoftware(KeyAlgorithm.RSA); "Generated an RSA key." }
                }
                RowDivider()
                ActionRow("About key types", Icons.Outlined.Info) { showAbout = true }
            }
        }
    }

    tokenDialog?.let { kind ->
        var pin by remember(kind) { mutableStateOf("") }
        val dismiss = { tokenDialog = null }
        AlertDialog(
            onDismissRequest = dismiss,
            title = { Text(if (kind == TokenKind.Fido) "FIDO2 security key" else "Smart card (PIV)") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        if (kind == TokenKind.Fido) "Create an SSH credential on your key, or import one already on it. You'll be asked to tap the key."
                        else "Enroll slot 9A (P-256). You'll be asked to tap or insert the card.",
                        fontSize = 14.sp,
                    )
                    OutlinedTextField(pin, { pin = it }, singleLine = true,
                        label = { Text(if (kind == TokenKind.Fido) "Security-key PIN" else "PIV PIN") },
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword))
                }
            },
            confirmButton = {
                if (kind == TokenKind.Fido) {
                    Row {
                        TextButton(enabled = pin.isNotEmpty(), onClick = {
                            val p = pin; dismiss()
                            runKeyOp("importing…") {
                                if (keyManager.importFido(p) == 0) "Already added." else "Imported from the security key."
                            }
                        }) { Text("Import") }
                        TextButton(enabled = pin.isNotEmpty(), onClick = {
                            val p = pin; dismiss()
                            runKeyOp("creating…") { keyManager.enrollFido(p); "Created a FIDO2 key." }
                        }) { Text("Create") }
                    }
                } else {
                    TextButton(enabled = pin.isNotEmpty(), onClick = {
                        val p = pin; dismiss()
                        runKeyOp("enrolling…") { keyManager.enrollYubiKey(p); "Enrolled the smart card." }
                    }) { Text("Enroll") }
                }
            },
            dismissButton = { TextButton(onClick = dismiss) { Text("Cancel") } },
        )
    }

    if (showAbout) {
        AlertDialog(
            onDismissRequest = { showAbout = false },
            title = { Text("Key types") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Device key — generated inside the Android Keystore (StrongBox or TEE, as labeled) and never exportable. Always present.", fontSize = 14.sp)
                    Text("Device key with biometric — a second Keystore key that needs a strong fingerprint, face, or iris check for every signature, so the phone can't connect while unlocked but unattended. Add its public key to your servers and pick it per host.", fontSize = 14.sp)
                    Text("FIDO2 security key — an OpenSSH security-key credential on your YubiKey. The private key never leaves the token, and one authorized_keys line works on Android and iOS when the server supports OpenSSH FIDO2.", fontSize = 14.sp)
                    Text("Smart card (PIV) — slot 9A, P-256. Produces a plain ecdsa-sha2-nistp256 key every SSH server accepts; the same card works on Android and iOS.", fontSize = 14.sp)
                    Text("Software keys — encrypted at rest and exportable in an encrypted backup. Use RSA only for older gear that can't accept Ed25519 or ECDSA.", fontSize = 14.sp)
                }
            },
            confirmButton = { TextButton(onClick = { showAbout = false }) { Text("Close") } },
        )
    }

    confirmDelete?.let { k ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text(if (k.fido || k.yubiKey) "Forget key?" else "Delete key?") },
            text = {
                Text(
                    when {
                        k.fido || k.yubiKey -> "The app will stop using this key. It stays on the token.\n\n${k.fingerprint}"
                        k.protectedDeviceKey -> "This device key will be erased permanently. Servers that only trust it will refuse you.\n\n${k.fingerprint}"
                        else -> "This software key will be erased from this device permanently.\n\n${k.fingerprint}"
                    },
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    when {
                        k.yubiKey -> keyManager.forgetYubiKey(k.id)
                        k.fido -> keyManager.forgetFido(k.id)
                        k.protectedDeviceKey -> keyManager.removeProtectedDeviceKey()
                        else -> keyManager.deleteSoftware(k.id)
                    }
                    confirmDelete = null; refresh()
                }) { Text(if (k.fido || k.yubiKey) "Forget" else "Delete") }
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
            Modifier.fillMaxSize().padding(pad).padding(horizontal = Spacing.screen).verticalScroll(rememberScrollState())
                .padding(bottom = Spacing.screen),
            verticalArrangement = Arrangement.spacedBy(Spacing.section),
        ) {
            ScreenTitle("Known hosts") { TextButton(onClick = onBack) { Text("Done") } }
            Section(footer = "Host keys you've trusted on first connection. Forget one to be asked to verify it again.") {
                if (hosts.isEmpty()) {
                    Text("No trusted hosts yet.", fontSize = 14.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 12.dp))
                }
                hosts.forEachIndexed { i, h ->
                    if (i > 0) RowDivider()
                    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f).padding(end = 8.dp)) {
                            Text(h.id, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                                color = MaterialTheme.colorScheme.primary)
                            SelectionContainer {
                                Text(h.fingerprint, fontFamily = FontFamily.Monospace, fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                        TextButton(onClick = { confirmForget = h }) { Text("Forget") }
                    }
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

/** Which key authenticates the next connection: one radio row per key. */
@Composable
fun KeyPicker(keys: List<AppKey>, selectedId: String, onSelect: (String) -> Unit) {
    keys.forEachIndexed { i, k ->
        if (i > 0) RowDivider()
        val sel = k.id == selectedId
        Row(
            Modifier.fillMaxWidth().heightIn(min = Spacing.rowMinHeight).clickable { onSelect(k.id) },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(k.label, fontSize = 15.sp, modifier = Modifier.weight(1f),
                color = if (sel) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
            RadioButton(selected = sel, onClick = { onSelect(k.id) })
        }
    }
}
