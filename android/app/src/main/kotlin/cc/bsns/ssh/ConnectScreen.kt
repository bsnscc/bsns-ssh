package cc.bsns.ssh

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.outlined.BookmarkAdd
import androidx.compose.material.icons.outlined.FileDownload
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cc.bsns.ssh.core.SshKeyFormat
import cc.bsns.ssh.transport.OpenReason
import cc.bsns.ssh.transport.SshBridge
import cc.bsns.ssh.transport.SshSession
import cc.bsns.ssh.transport.TerminalTransport
import kotlin.concurrent.thread

/** The connect form's fields, held above [ConnectScreen] so they survive the
 *  screen leaving composition (a session, the file browser, another tab) — a
 *  disconnect returns to the form as it was. The password is the exception: it's
 *  cleared once used, so it isn't kept in UI state. */
class ConnectFormState {
    // Debug builds prefill the local emulator sshd for fast iteration; release
    // builds start blank with the standard SSH port.
    var host by mutableStateOf(if (BuildConfig.DEBUG) "10.0.2.2" else "")
    var port by mutableStateOf(if (BuildConfig.DEBUG) "2222" else "22")
    var user by mutableStateOf(if (BuildConfig.DEBUG) "tester" else "")
    var group by mutableStateOf("")
    var jump by mutableStateOf("")
    var password by mutableStateOf("")
    var useMosh by mutableStateOf(false)
}

/** Human-readable message for a failed SSH open, mirroring the categories in
 *  iOS TerminalSession.describe so both platforms speak the same language. */
fun describeOpenFailure(reason: OpenReason, usedPassword: Boolean = false): String = when (reason) {
    OpenReason.Unreachable -> "Couldn't reach the server. Check the host, port, and your network."
    OpenReason.Handshake -> "SSH handshake failed — the server may not speak SSH, or uses unsupported algorithms."
    OpenReason.Auth -> if (usedPassword) "Authentication failed — check the username and password."
        else "Authentication failed — is your key installed on the server?"
    OpenReason.HostKeyMismatch -> "⚠️ The host key changed — possible interception. Connection refused."
    OpenReason.NoShell -> "Couldn't open a shell on the server."
    OpenReason.Ok -> "Couldn't open the session."
}

@Composable
fun ConnectScreen(
    form: ConnectFormState,
    key: AppKey,
    keys: List<AppKey>,
    reloadKey: Int = 0,
    onSelectKey: (String) -> Unit,
    onImport: () -> Unit,
    onSftp: (SftpTarget) -> Unit,
    forwardsActive: Boolean,
    onReopenForwards: () -> Unit,
    onForwards: (cc.bsns.ssh.transport.ForwardSession) -> Unit,
    onConnected: (TerminalTransport, String, () -> TerminalTransport?) -> Unit,
) {
    var host by form::host
    var port by form::port
    var user by form::user
    var group by form::group
    var jump by form::jump
    var password by form::password
    var useMosh by form::useMosh
    var showPassword by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var showYubiPin by remember { mutableStateOf(false) }
    var yubiPin by remember { mutableStateOf("") }
    var afterPin by remember { mutableStateOf<(() -> Unit)?>(null) }
    // Jump host + folder live behind "More options"; open it when either is set
    // (e.g. a loaded saved host) so a value is never hidden.
    var moreOptions by remember { mutableStateOf(jump.isNotBlank() || group.isNotBlank()) }

    val authLine = key.authLine

    // A YubiKey (PIV) or FIDO2 key signs only after its PIN is supplied — prompt
    // once per unlock, then proceed.
    fun withYubiPin(action: () -> Unit) {
        val needsPin = (key.yubiKey && !YubiKeyManager.unlocked) || (key.fido && !FidoKeyManager.unlocked)
        if (needsPin) { afterPin = action; showYubiPin = true } else action()
    }

    val context = LocalContext.current
    val hostStore = remember { HostStore(context) }
    // reloadKey bumps after an auto-sync pull so freshly-merged hosts appear.
    var savedHosts by remember(reloadKey) { mutableStateOf(hostStore.load()) }
    val knownHosts = remember { KnownHostsStore(context) }
    var pendingTofu by remember { mutableStateOf<TofuInfo?>(null) }
    var pendingBastionTofu by remember { mutableStateOf<BastionTofu?>(null) }
    var pendingMismatch by remember { mutableStateOf<MismatchInfo?>(null) }
    var pendingAction by remember { mutableStateOf<((Int, ByteArray) -> Unit)?>(null) }
    // A saved host queued for delete-confirm and one queued for quick-connect.
    // Quick-connect loads the host's fields, then a LaunchedEffect fires the
    // connect once state reflects the load (state writes aren't visible in the
    // same frame).
    var pendingRemove by remember { mutableStateOf<SavedHost?>(null) }
    var quickConnectTick by remember { mutableStateOf(0) }

    fun openWith(p: Int, blob: ByteArray) {
        busy = true; status = "connecting…"
        // verifyThen already validated the jump spec, so anything but Ok is treated
        // as no jump here.
        val js = (parseJump(jump.trim().ifEmpty { null }, user) as? JumpParse.Ok)?.spec
        val title = if (js != null) "$user@$host:$p ⇢ ${js.host}" else "$user@$host:$p"
        // The bastion was verified by verifyThen, so its trusted key is in the store —
        // pin it on the tunnel so the bastion is re-verified on connect + reconnect.
        val bastionKey = js?.let { knownHosts.trustedBlob(it.host, it.port) }
        // FIDO2 keys authenticate via libssh2's sk path (direct only) using an
        // OpenSSH-format sk private key (the credential handle, not a secret).
        val skPem = (key.signer as? FidoSkKey)?.privatePem
        // A password logs in to the target instead of the key (iOS parity); the
        // bastion, if any, still uses the key. Captured for reconnects, then
        // cleared from the form below once the session is up.
        val pw = password.ifEmpty { null }?.takeIf { skPem == null }
        // The same factory does the initial open and any later reconnect-on-drop.
        // On a failed open it stashes the SshSession's reason category so the UI
        // can say *why* (auth vs unreachable vs no shell vs host-key change).
        var lastReason: OpenReason = OpenReason.Unreachable
        val factory: () -> TerminalTransport? = {
            val s = SshSession(host, p, user, key.publicKeyBlob, key.signer, expectedHostKey = blob,
                jumpHost = js?.host, jumpPort = js?.port ?: 22, jumpUser = js?.user,
                expectedBastionHostKey = bastionKey, skPrivatePem = skPem, password = pw)
            if (s.open(80, 24)) s else { lastReason = s.lastError; null }
        }
        thread {
            val s = factory()
            if (s != null) main.post {
                busy = false
                password = ""   // don't keep the password in UI state after use
                onConnected(s, title, factory)
            }
            else main.post { busy = false; status = describeOpenFailure(lastReason, usedPassword = pw != null) }
        }
    }

    // Open a dedicated forwarding connection (host key already verified).
    fun openForwards(p: Int, blob: ByteArray) {
        busy = true; status = "opening tunnel connection…"
        thread {
            val fs = cc.bsns.ssh.transport.ForwardSession(host, p, user, key.publicKeyBlob, key.signer, expectedHostKey = blob)
            if (fs.open()) main.post { busy = false; onForwards(fs) }
            else {
                // The forward open goes through the same libssh2 open as Connect, so
                // its per-category reason is in the process-global last-open reason —
                // surface the same auth/unreachable/no-shell language as Connect.
                val reason = OpenReason.fromCode(SshBridge().nativeLastOpenReason())
                main.post { busy = false; status = describeOpenFailure(reason) }
            }
        }
    }

    // mosh: SSH in (host-key pinned) → run mosh-server → parse MOSH CONNECT → open
    // the UDP transport. The factory re-bootstraps on a dropped/expired session.
    fun openMosh(p: Int, blob: ByteArray) {
        busy = true; status = "starting mosh-server…"
        val skPem = (key.signer as? FidoSkKey)?.privatePem
        // Captures why a bootstrap attempt failed (set + read on the same worker
        // thread, where the native per-thread open-reason is valid).
        var bootstrapError: String? = null
        // A mosh-server we abandon (app killed, or a resume that failed and
        // re-bootstrapped) can never be reached again — a new client restarts the
        // crypto sequence at 0 and the server rejects it — so it would keep
        // running and holding a PTY. Tie each server we start to this session id
        // so the next bootstrap can ask the abandoned ones to quit.
        val sessionId = java.util.UUID.randomUUID().toString()
        val registry = MoshServerRegistry(context)
        val hostKey = MoshServerRegistry.hostKey(host, p, user)
        val idleTimeoutSeconds = SettingsStore(context).moshIdleTimeoutHours * 3600
        val factory: () -> TerminalTransport? = {
            bootstrapError = null
            registry.abandon(sessionId)   // re-bootstrapping ⇒ our previous server is orphaned
            val cmd = MoshBootstrap.serverCommand(idleTimeoutSeconds, registry.reapablePids(hostKey))
            val bridge = SshBridge()
            val out = if (skPem != null)
                bridge.nativeAuthAndExecSk(host, p, user, key.publicKeyBlob, skPem, key.signer,
                    cmd, blob)
            else bridge.nativeAuthAndExec(host, p, user, key.publicKeyBlob, key.signer,
                cmd, blob)
            when {
                // null = the SSH side failed (couldn't reach / wrong key / host-key
                // mismatch). Report THAT, not a misleading "is mosh on the host?".
                out == null -> {
                    bootstrapError = describeOpenFailure(OpenReason.fromCode(bridge.nativeLastOpenReason()))
                    null
                }
                else -> {
                    val conn = MoshBootstrap.parse(out)
                    when {
                        conn == null -> {   // SSH worked but no MOSH CONNECT line — genuinely a mosh-server issue
                            bootstrapError = "mosh-server didn't start (is mosh installed on the host?)"
                            null
                        }
                        else -> {
                            val m = cc.bsns.ssh.transport.MoshSession(host, conn.port, conn.key)
                            m.serverPid = conn.pid
                            registry.record(conn.pid, hostKey, sessionId)
                            // On teardown the server either acknowledged our shutdown
                            // (it's exiting) or it's still out there needing a reap.
                            m.onFinished = { acknowledged ->
                                if (m.serverPid > 0) {
                                    if (acknowledged) registry.forget(m.serverPid, hostKey) else registry.abandon(m.serverPid, hostKey)
                                }
                            }
                            if (m.open(80, 24)) m
                            else {
                                registry.abandon(conn.pid, hostKey)   // started but unreachable — reap it next time
                                bootstrapError = "reached the host, but couldn't open the mosh UDP session"
                                null
                            }
                        }
                    }
                }
            }
        }
        thread {
            val m = factory()
            if (m != null) main.post { busy = false; onConnected(m, "mosh·$user@$host", factory) }
            else { val err = bootstrapError ?: "couldn't start mosh"; main.post { busy = false; status = err } }
        }
    }

    // Verify the host key (TOFU), then run the chosen action. With a jump host this
    // is two-stage: trust the BASTION's own key first (before any auth to it), then
    // the target's key fetched through the now-verified tunnel.
    fun verifyThen(action: (Int, ByteArray) -> Unit) {
        val p = validPort(port)
        if (p == null) { status = "port must be a number from 1 to 65535"; return }
        val js = when (val j = parseJump(jump.trim().ifEmpty { null }, user)) {
            is JumpParse.Invalid -> { status = j.message; return }
            is JumpParse.Ok -> j.spec
            JumpParse.None -> null
        }
        busy = true; status = if (js != null) "verifying jump host ${js.host}…" else "verifying host…"
        thread {
            // Stage 1: the bastion's own key (direct), trusted before we auth to it.
            val bastionKey: ByteArray?
            if (js != null) {
                val bkey = SshBridge().nativeHostKeyBlob(js.host, js.port)
                if (bkey == null) { main.post { busy = false; status = "couldn't reach jump host ${js.host}:${js.port}" }; return@thread }
                val bt = knownHosts.trustedBlob(js.host, js.port)
                when {
                    bt == null -> { main.post { busy = false; pendingAction = action; pendingBastionTofu = BastionTofu(js.host, js.port, bkey) }; return@thread }
                    !bt.contentEquals(bkey) -> { main.post { busy = false
                        pendingAction = action
                        pendingMismatch = MismatchInfo(js.host, js.port, bt, bkey, isJump = true) }; return@thread }
                }
                bastionKey = bkey
            } else bastionKey = null

            // Stage 2: the target's key — fetched THROUGH the tunnel (re-verifying the
            // bastion) for a jump, or directly otherwise. Compose state must change
            // on the main thread, never this worker.
            if (js != null) main.post { status = "verifying host via ${js.host}…" }
            val blob = if (js != null)
                SshBridge().nativeHostKeyBlobVia(host, p, js.host, js.port, js.user, key.publicKeyBlob, key.signer, bastionKey)
            else SshBridge().nativeHostKeyBlob(host, p)
            val trusted = if (blob != null) knownHosts.trustedBlob(host, p) else null
            when {
                blob == null -> main.post { busy = false; status = "couldn't reach $host:$p" }
                trusted == null -> main.post { busy = false; pendingAction = action; pendingTofu = TofuInfo(p, blob) }
                !trusted.contentEquals(blob) -> main.post {
                    busy = false
                    pendingAction = action
                    pendingMismatch = MismatchInfo(host, p, trusted, blob, isJump = false)
                }
                else -> main.post { busy = false; action(p, blob) }
            }
        }
    }

    val hasJump = jump.trim().isNotEmpty()
    val fidoKey = key.fido
    val jumpWithFido = hasJump && fidoKey
    var showPublicKey by remember { mutableStateOf(false) }

    // The shared connect path used by both the Connect button and quick-connect:
    // verify the host key, then open a shell (or mosh, when enabled + no jump host).
    fun connectNow() {
        if (busy || jumpWithFido) return
        withYubiPin { verifyThen { p, blob -> if (useMosh && !hasJump) openMosh(p, blob) else openWith(p, blob) } }
    }
    // Quick-connect: ConnectScreen has already loaded the host's fields and bumped
    // quickConnectTick; fire once state reflects the load (skip the initial 0).
    LaunchedEffect(quickConnectTick) { if (quickConnectTick > 0) connectNow() }

    fun installKey() {
        // Verify the host key first (same TOFU prompt as Connect) so the server
        // password is never sent to an unverified host.
        verifyThen { p, blob ->
            busy = true; status = "installing key…"
            val pw = password
            thread {
                val bridge = SshBridge()
                val ok = bridge.nativeInstallKey(host, p, user, pw, authLine, blob)
                // On failure, distinguish auth (wrong password) vs unreachable vs
                // no-shell via the same last-open reason Connect uses, instead of a
                // flat "install failed".
                val reason = if (ok) OpenReason.Ok
                    else OpenReason.fromCode(bridge.nativeLastOpenReason())
                main.post {
                    busy = false
                    if (ok) password = ""   // don't keep the password in UI state after use
                    status = if (ok) "Key installed — you can now connect with it."
                        else "Install failed — ${describeOpenFailure(reason, usedPassword = true)}"
                }
            }
        }
    }

    @Composable
    fun savedHostsBlock() {
            // Saved hosts — one card per folder.
            if (savedHosts.isNotEmpty()) {
                val grouped = savedHosts.groupBy { it.group?.trim()?.ifEmpty { null } }
                val sections = grouped.keys.filterNotNull().sorted() + (if (grouped.containsKey(null)) listOf<String?>(null) else emptyList())
                sections.forEach { g ->
                    Section(title = g ?: "Saved hosts") {
                        grouped[g]!!.forEachIndexed { i, h ->
                            if (i > 0) RowDivider()
                            // Load the host's fields into the form (shared by row-tap +
                            // quick-connect).
                            val loadHost = {
                                host = h.host; port = h.port.toString(); user = h.user
                                group = h.group ?: ""; jump = h.jump ?: ""
                                useMosh = h.useMosh
                                if (jump.isNotBlank() || group.isNotBlank()) moreOptions = true
                                if (h.keyId != null && keys.any { it.id == h.keyId }) onSelectKey(h.keyId)
                            }
                            // Which key this host is bound to — its label, or a clear
                            // fallback so a stale/missing pin doesn't silently mislead.
                            val boundKeyLabel = when {
                                h.keyId == null -> null
                                else -> keys.firstOrNull { it.id == h.keyId }?.label
                                    ?: "key no longer available — using default"
                            }
                            Row(
                                // Whole row loads the host (a big, reliable tap target); the
                                // Connect button loads + connects, the ✕ asks to remove.
                                Modifier.fillMaxWidth().heightIn(min = Spacing.rowMinHeight).clickable {
                                    loadHost(); status = "loaded ${h.label}"
                                },
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(Modifier.weight(1f).padding(vertical = 6.dp)) {
                                    Text(h.label, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                                        color = MaterialTheme.colorScheme.primary)
                                    h.jump?.let {
                                        Text("⇢ $it", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                    boundKeyLabel?.let {
                                        Text("🔑 $it", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                    if (h.useMosh) Text("mosh", fontSize = 11.sp, color = Brand.accent)
                                }
                                // One-tap connect (load + connect), mirroring iOS quick-connect.
                                OutlinedButton(
                                    enabled = !busy,
                                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp),
                                    onClick = {
                                        loadHost(); status = "connecting to ${h.label}…"; quickConnectTick++
                                    },
                                ) { Text("Connect", fontSize = 13.sp) }
                                IconButton(onClick = { pendingRemove = h }) {
                                    Icon(Icons.Default.Close, "remove ${h.label}", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                    }
                }
            } else {
                // No saved hosts yet — hint that the feature exists (iOS ConnectView parity).
                Section(title = "Saved hosts") {
                    Column(Modifier.fillMaxWidth().padding(vertical = 10.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("No saved hosts yet", fontSize = 14.sp,
                            color = MaterialTheme.colorScheme.onSurface)
                        Text("Fill in a server below, then Save host to keep it here for one-tap connect.",
                            fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
    }

    @Composable
    fun formBlock() {
            // Connection inputs: grouped rows with short labels and example
            // placeholders; host and port share a row.
            Section(
                title = "Server",
                footer = if (password.isEmpty()) "Leave the password empty to log in with your key."
                    else "Logs in with the password. Mosh, file browsing, and tunnels still use your key — " +
                        "Install my key below adds it to the server.",
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FormField("Host", host, { host = it }, placeholder = "example.com",
                        keyboardType = KeyboardType.Uri, modifier = Modifier.weight(1f))
                    Text(":", fontSize = 15.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 6.dp))
                    FormField("", port, { port = it }, placeholder = "22", description = "Port",
                        keyboardType = KeyboardType.Number, modifier = Modifier.width(56.dp))
                }
                RowDivider()
                FormField("User", user, { user = it }, placeholder = "root")
                RowDivider()
                FormField(
                    "Password", password, { password = it }, placeholder = "optional",
                    secret = !showPassword,
                    trailing = {
                        if (password.isNotEmpty()) TextButton(onClick = { showPassword = !showPassword }) {
                            Text(if (showPassword) "Hide" else "Show", fontSize = 13.sp)
                        }
                    },
                )
            }

            Section(
                footer = when {
                    hasJump -> "Via a jump host, only an interactive shell is supported for now — " +
                        "mosh, file browsing, tunnels, and key install are off."
                    fidoKey -> "FIDO2 security keys connect directly to a shell or mosh — file browsing, " +
                        "tunnels, and jump hosts aren't supported with these keys yet."
                    else -> null
                },
            ) {
                SettingRow(if (hasJump) "Use mosh (off with a jump host)" else "Use mosh", enabled = !hasJump) {
                    Switch(checked = useMosh, enabled = !hasJump, onCheckedChange = { useMosh = it })
                }
                RowDivider()
                SettingRow("More options", onClick = { moreOptions = !moreOptions }) {
                    Icon(if (moreOptions) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                        contentDescription = if (moreOptions) "hide" else "show",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (moreOptions) {
                    RowDivider()
                    FormField("Jump host", jump, { jump = it }, placeholder = "user@bastion:22",
                        keyboardType = KeyboardType.Uri)
                    RowDivider()
                    FormField("Folder", group, { group = it }, placeholder = "for saved hosts")
                }
            }

            if (keys.size > 1) {
                Section(title = "Key") { KeyPicker(keys, key.id, onSelectKey) }
            }

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    enabled = !busy && !jumpWithFido && host.isNotBlank() && user.isNotBlank(),
                    onClick = { connectNow() },
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
                ) {
                    Text(
                        when {
                            busy -> "Working…"
                            useMosh && !hasJump -> "Connect (mosh)"
                            else -> "Connect"
                        },
                        fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                    )
                }
                // Why Connect won't work yet, so an empty form reads as "fill this
                // in", not a broken button (iOS ConnectView parity).
                val connectHint = when {
                    busy -> null
                    host.isBlank() || user.isBlank() -> "Enter a host and user to connect over SSH."
                    else -> null
                }
                (status ?: connectHint)?.let {
                    Text(it, fontSize = 13.sp,
                        color = if (status != null) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 6.dp))
                }
            }

            // Secondary actions as rows, so none get clipped off the screen edge.
            Section {
                val ready = !busy && host.isNotBlank() && user.isNotBlank()
                ActionRow("Browse files (SFTP)", Icons.Outlined.Folder, enabled = ready && !hasJump && !fidoKey) {
                    withYubiPin {
                        verifyThen { p, blob ->
                            onSftp(SftpTarget(host, p, user, key.publicKeyBlob, key.signer, blob))
                        }
                    }
                }
                RowDivider()
                ActionRow(
                    "Tunnels (port forwarding)", Icons.Outlined.SwapHoriz,
                    enabled = (forwardsActive || ready) && !hasJump && !fidoKey,
                    detail = if (forwardsActive) "active" else null,
                ) {
                    if (forwardsActive) onReopenForwards()
                    else withYubiPin { verifyThen { p, blob -> openForwards(p, blob) } }
                }
                RowDivider()
                ActionRow(
                    "Install my key (ssh-copy-id)", Icons.Outlined.Key,
                    enabled = ready && password.isNotEmpty() && !hasJump,
                    detail = if (password.isEmpty()) "needs password" else null,
                ) { installKey() }
                RowDivider()
                ActionRow("Save host", Icons.Outlined.BookmarkAdd, enabled = host.isNotBlank() && user.isNotBlank()) {
                    val p = validPort(port)
                    if (p == null) { status = "port must be a number from 1 to 65535" }
                    else {
                        savedHosts = hostStore.add(SavedHost(host, p, user,
                            jump = jump.trim().ifEmpty { null }, group = group.trim().ifEmpty { null },
                            keyId = key.id, useMosh = useMosh))
                        status = "saved $user@$host"
                    }
                }
                RowDivider()
                ActionRow("Import from OpenSSH (~/.ssh)", Icons.Outlined.FileDownload) { onImport() }
            }

            // The public key is a wall of base64, rarely needed — keep it in a card, collapsed.
            Section {
                Row(
                    Modifier.fillMaxWidth().heightIn(min = Spacing.rowMinHeight)
                        .clickable { showPublicKey = !showPublicKey },
                    horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("My public key", fontSize = 15.sp)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = { copyToClipboard(context, "public key", authLine) }) { Text("Copy") }
                        Icon(if (showPublicKey) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                            contentDescription = if (showPublicKey) "hide" else "show",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (showPublicKey) {
                    Text("Add to the server's ~/.ssh/authorized_keys:", fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(bottom = 4.dp))
                    SelectionContainer {
                        Text(authLine, fontFamily = FontFamily.Monospace, fontSize = 10.sp,
                            modifier = Modifier.padding(bottom = 8.dp))
                    }
                }
            }
    }

    Scaffold { pad ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(pad)) {
            val column = Arrangement.spacedBy(Spacing.section)
            if (maxWidth >= 760.dp) {
                // iPad parity: with the room, the saved hosts sit beside the form
                // instead of pushing it below the fold. Each side scrolls on its own.
                Row(Modifier.fillMaxSize().padding(horizontal = Spacing.screen),
                    horizontalArrangement = Arrangement.spacedBy(28.dp)) {
                    Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState())
                        .padding(bottom = Spacing.screen), verticalArrangement = column) {
                        ScreenTitle("Connect")
                        savedHostsBlock()
                    }
                    Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState())
                        .padding(bottom = Spacing.screen), verticalArrangement = column) {
                        ScreenTitle("")   // an empty title row, so both columns' cards line up
                        formBlock()
                    }
                }
            } else {
                Column(
                    Modifier.fillMaxSize().padding(horizontal = Spacing.screen).verticalScroll(rememberScrollState())
                        .padding(bottom = Spacing.screen),
                    verticalArrangement = column,
                ) {
                    ScreenTitle("Connect")
                    savedHostsBlock()
                    formBlock()
                }
            }
        }
    }

    // Confirm before removing a saved host — the ✕ used to delete instantly.
    pendingRemove?.let { h ->
        AlertDialog(
            onDismissRequest = { pendingRemove = null },
            title = { Text("Remove saved host?") },
            text = { Text("Remove ${h.label} from your saved hosts? This doesn't affect the server.") },
            confirmButton = {
                TextButton(onClick = { pendingRemove = null }) { Text("Cancel") }
            },
            dismissButton = {
                TextButton(onClick = {
                    savedHosts = hostStore.remove(h); pendingRemove = null
                }) { Text("Remove") }
            },
        )
    }

    pendingTofu?.let { tofu ->
        val fp = remember(tofu) { SshKeyFormat.fingerprintOfPublicKeyBlob(tofu.blob) }
        AlertDialog(
            onDismissRequest = { pendingTofu = null; pendingAction = null; status = null },
            title = { Text("Verify host key") },
            text = {
                Text(
                    "First connection to $user@$host:${tofu.port}.\n\n$fp\n\n" +
                        "Only trust this if the fingerprint matches what the server's admin gave you out of band.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    knownHosts.trust(host, tofu.port, tofu.blob)
                    val info = tofu
                    val act = pendingAction
                    pendingTofu = null
                    pendingAction = null
                    (act ?: { p, b -> openWith(p, b) })(info.port, info.blob)
                }) { Text("Trust") }
            },
            dismissButton = {
                TextButton(onClick = { pendingTofu = null; pendingAction = null; status = null }) { Text("Cancel") }
            },
        )
    }

    pendingBastionTofu?.let { bt ->
        val fp = remember(bt) { SshKeyFormat.fingerprintOfPublicKeyBlob(bt.blob) }
        AlertDialog(
            onDismissRequest = { pendingBastionTofu = null; pendingAction = null; status = null },
            title = { Text("Verify jump host key") },
            text = {
                Text(
                    "First connection to the jump host ${bt.host}:${bt.port}.\n\n$fp\n\n" +
                        "You're routing through this bastion to reach $host. Trust it only if the " +
                        "fingerprint matches what its admin gave you out of band.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    knownHosts.trust(bt.host, bt.port, bt.blob)
                    val act = pendingAction
                    pendingBastionTofu = null
                    // Bastion now trusted → re-run verification (proceeds to the target).
                    if (act != null) verifyThen(act)
                }) { Text("Trust") }
            },
            dismissButton = {
                TextButton(onClick = { pendingBastionTofu = null; pendingAction = null; status = null }) { Text("Cancel") }
            },
        )
    }

    pendingMismatch?.let { mm ->
        val storedFp = remember(mm) { SshKeyFormat.fingerprintOfPublicKeyBlob(mm.stored) }
        val presentedFp = remember(mm) { SshKeyFormat.fingerprintOfPublicKeyBlob(mm.presented) }
        val label = if (mm.isJump) "jump host" else "host"
        AlertDialog(
            onDismissRequest = { pendingMismatch = null; pendingAction = null; status = null },
            title = { Text("⚠ Host key changed") },
            text = {
                Text(
                    "The $label key for ${mm.host}:${mm.port} no longer matches the one you " +
                        "trusted. This can mean the server was rebuilt — or that someone is " +
                        "intercepting the connection.\n\n" +
                        "trusted:  $storedFp\n" +
                        "now:      $presentedFp\n\n" +
                        "Only forget the saved key if you verified the new fingerprint out of band. " +
                        "You'll be asked to verify it again before connecting.",
                )
            },
            // Cancel is the PROMINENT (affirmative) action so a reflex confirm
            // doesn't forget a possibly-MITM'd key. Forgetting is the secondary.
            confirmButton = {
                TextButton(onClick = { pendingMismatch = null; pendingAction = null; status = null }) { Text("Cancel") }
            },
            dismissButton = {
                TextButton(onClick = {
                    // Forget the stale key, then re-run verification — which falls
                    // through to a fresh TOFU prompt on the new key (never a silent
                    // re-trust). For a jump mismatch, verifyThen re-checks the bastion
                    // first; for a target mismatch it re-checks the target.
                    knownHosts.forget(mm.host, mm.port)
                    val act = pendingAction
                    pendingMismatch = null
                    if (act != null) verifyThen(act)
                }) { Text("Forget key") }
            },
        )
    }

    if (showYubiPin) {
        AlertDialog(
            onDismissRequest = { showYubiPin = false; yubiPin = ""; afterPin = null },
            title = { Text(if (key.fido) "Security key PIN" else "YubiKey PIN") },
            text = {
                OutlinedTextField(yubiPin, { yubiPin = it }, label = { Text("PIN") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation())
            },
            confirmButton = {
                TextButton(onClick = {
                    if (key.fido) FidoKeyManager.setPin(yubiPin) else YubiKeyManager.setPin(yubiPin)
                    yubiPin = ""; showYubiPin = false
                    val act = afterPin; afterPin = null; act?.invoke()
                }) { Text("Continue") }
            },
            dismissButton = {
                TextButton(onClick = { showYubiPin = false; yubiPin = ""; afterPin = null }) { Text("Cancel") }
            },
        )
    }
}

private class TofuInfo(val port: Int, val blob: ByteArray)
private class BastionTofu(val host: String, val port: Int, val blob: ByteArray)

/** A host whose presented key no longer matches the one we trusted. Carries
 *  everything the recovery dialog needs to forget the stale key and re-verify.
 *  `isJump` distinguishes the bastion's own key from the target's. */
private class MismatchInfo(
    val host: String,
    val port: Int,
    val stored: ByteArray,
    val presented: ByteArray,
    val isJump: Boolean,
)
