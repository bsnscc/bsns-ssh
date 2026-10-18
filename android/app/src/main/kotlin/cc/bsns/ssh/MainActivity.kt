package cc.bsns.ssh

import android.annotation.SuppressLint
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.KeyboardShortcutGroup
import android.view.Menu
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.CropSquare
import androidx.compose.material.icons.outlined.VerticalSplit
import androidx.compose.material.icons.outlined.ViewSidebar
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.concurrent.thread

class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Draw behind the system bars on every API level (15+ enforces it anyway),
        // so window insets reach Compose the same way everywhere and each screen
        // pads for the status bar, navigation bar, and keyboard itself. The app is
        // dark-only, so the bar icons stay light.
        val bars = SystemBarStyle.dark(Brand.nearBlack.toArgb())
        enableEdgeToEdge(statusBarStyle = bars, navigationBarStyle = bars)
        super.onCreate(savedInstanceState)
        YubiKeyManager.attach(this)   // for NFC reader-mode + USB discovery
        FidoKeyManager.attach(this)   // FIDO2/CTAP2 over the same NFC/USB transports
        // Per-use biometric prompt for an auth-required (protected) Keystore key.
        cc.bsns.ssh.transport.KeystoreSigner.authorizer = BiometricKeyAuthorizer(this)
        // Set the secure flag up front so the very first recents snapshot is
        // protected — don't wait for a resume round-trip (a privacy guarantee).
        applySecureFlag(window, SettingsStore(this).appLock)
        // Any mosh-server started by a previous run of the app is orphaned: its
        // client's crypto state died with the process, so nothing here can reach
        // it again. Mark them reapable by the next connect to that host, or they
        // sit on the host holding a PTY until their idle timeout.
        MoshServerRegistry(this).markAllAbandonedFromPreviousRun()
        // Brand-tinted dark scheme: the icon's #00C29C accent on the #0F0F0F near-black,
        // so buttons, switches, and selected states match the icon + the iOS app.
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(
                primary = Brand.accent,
                secondary = Brand.accent,
                tertiary = Brand.accent,
                background = Brand.nearBlack,
                surface = Brand.nearBlack,
                surfaceVariant = Brand.surface,
                onPrimary = Brand.nearBlack,
                // Neutral on*-roles so content reads as light gray on the near-black
                // background instead of Material's purple-tinted defaults.
                onSurface = Color(0xFFE8E8E8),
                onBackground = Color(0xFFE8E8E8),
                onSurfaceVariant = Color(0xFFB8B8B8),
                error = Color(0xFFFF6B6B),
                outline = Color(0xFF555555),
            )) {
                // Wrap in a Surface so LocalContentColor resolves to onSurface (light)
                // everywhere — not just inside Scaffold screens. Without it, content
                // that isn't under a Scaffold (the terminal pane's top-bar icons)
                // inherits Material's default black content color → invisible on the
                // near-black background.
                Surface(modifier = Modifier.fillMaxSize()) { App() }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        applySecureFlag(window, SettingsStore(this).appLock)
    }

    // Session shortcuts get first look at hardware keys, ahead of the terminal view.
    // (Lint's RestrictedApi hit is AndroidX re-annotating the public framework
    // Activity.dispatchKeyEvent; overriding it is ordinary platform API.)
    @SuppressLint("RestrictedApi")
    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        AppShortcuts.dispatch(event) || super.dispatchKeyEvent(event)

    override fun onProvideKeyboardShortcuts(data: MutableList<KeyboardShortcutGroup>, menu: Menu?, deviceId: Int) {
        super.onProvideKeyboardShortcuts(data, menu, deviceId)
        data.add(AppShortcuts.group())
    }

    override fun onStop() {
        super.onStop()
        YubiKeyManager.lock()   // forget the cached YubiKey PIN when backgrounded
        FidoKeyManager.lock()   // and the FIDO2 PIN
        // Auto-sync: push the latest config to the user's folder on background.
        if (SyncStore(this).enabled) {
            val app = applicationContext
            thread { runCatching { ConfigSync.push(app) } }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        // Drop the activity-bound biometric authorizer so we don't leak this activity.
        cc.bsns.ssh.transport.KeystoreSigner.authorizer = null
    }
}

/** Toggle FLAG_SECURE so terminal/key content is excluded from the recents
 *  snapshot and screenshots whenever app lock is on. Applied at create, on
 *  resume, and the instant the setting changes — never gated on a lifecycle trip. */
fun applySecureFlag(window: android.view.Window, secure: Boolean) {
    if (secure) {
        window.setFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE,
            android.view.WindowManager.LayoutParams.FLAG_SECURE)
    } else {
        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
    }
}

internal val main = Handler(Looper.getMainLooper())

/** Parse a port, returning null unless it's a valid 1..65535 — no silent
 *  fallback to 22 that could connect to / trust / save the wrong endpoint. */
fun validPort(text: String): Int? = text.trim().toIntOrNull()?.takeIf { it in 1..65535 }

/** A single ProxyJump hop. */
data class JumpSpec(val host: String, val port: Int, val user: String)

/** Outcome of parsing a ProxyJump spec. `Invalid` is distinct from `None` so an
 *  explicit-but-malformed bastion is rejected, never silently dropped or pointed
 *  at the wrong port. */
sealed interface JumpParse {
    object None : JumpParse
    data class Ok(val spec: JumpSpec) : JumpParse
    data class Invalid(val message: String) : JumpParse
}

/** Parse the first hop of a ProxyJump spec ("user@bastion[:port][,…]"). A missing
 *  user falls back to the target user; multi-hop chains use the first hop for now.
 *  A port outside 1..65535 is rejected rather than falling back to 22. */
fun parseJump(spec: String?, fallbackUser: String): JumpParse {
    val first = spec?.split(",")?.firstOrNull()?.trim()?.takeIf { it.isNotEmpty() } ?: return JumpParse.None
    val at = first.indexOf('@')
    val who = if (at >= 0) first.substring(0, at) else fallbackUser
    val hp = if (at >= 0) first.substring(at + 1) else first
    // Any colon that isn't the first char means an explicit port: require it to be
    // valid (matches iOS), so "host:", "host:abc", "host:0" are rejected rather than
    // silently treated as a hostname on port 22.
    val colon = hp.lastIndexOf(':')
    if (colon > 0) {
        val port = hp.substring(colon + 1).toIntOrNull()?.takeIf { it in 1..65535 }
            ?: return JumpParse.Invalid("jump host port must be a number from 1 to 65535")
        return JumpParse.Ok(JumpSpec(hp.substring(0, colon), port, who))
    }
    return JumpParse.Ok(JumpSpec(hp, 22, who))
}

/** The three top-level tabs, matching the iOS tab bar. */
private enum class Tab(val label: String, val icon: ImageVector) {
    Connect("Connect", Icons.Outlined.Terminal),
    Keys("Keys", Icons.Outlined.Key),
    Settings("Settings", Icons.Outlined.Settings),
}

/** Every screen reachable without a live session. Each belongs to a tab; the
 *  tab's root shows the bottom bar, and a sub-screen goes Back to its parent. */
private enum class Route(val tab: Tab, val parent: Route? = null) {
    Connect(Tab.Connect),
    Import(Tab.Connect, Connect),
    Keys(Tab.Keys),
    Settings(Tab.Settings),
    Hosts(Tab.Settings, Settings),
    Backup(Tab.Settings, Settings),
    Snippets(Tab.Settings, Settings),
    Help(Tab.Settings, Settings);

    companion object {
        fun root(tab: Tab) = entries.first { it.tab == tab && it.parent == null }
    }
}

@Composable
fun App() {
    val context = LocalContext.current
    // The available keys: the always-present hardware Keystore key + software keys.
    val keyManager = remember { KeyManager(context) }
    var keys by remember { mutableStateOf(keyManager.keys()) }
    var selectedKeyId by remember { mutableStateOf(keys.first().id) }
    val selectedKey = keys.firstOrNull { it.id == selectedKeyId } ?: keys.first()

    val settings = remember { SettingsStore(context) }
    // The connect form outlives ConnectScreen (which leaves composition while a
    // session or sub-screen is up), so coming back doesn't wipe what was typed.
    val connectForm = remember { ConnectFormState() }

    // Auto-sync: pull + merge the user's folder once on launch, then refresh the
    // in-memory keys/hosts (syncTick re-reads the saved list on the connect screen).
    var syncTick by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) {
        if (SyncStore(context).enabled) {
            val applied = withContext(Dispatchers.IO) { runCatching { ConfigSync.pull(context) }.getOrNull() }
            if (applied != null && !applied.isEmpty) {
                keys = keyManager.keys()
                syncTick++
            }
        }
    }

    // App lock: require device authentication at launch and after each backgrounding.
    val lockEnabled = settings.appLock && biometricAvailable(context)
    var unlocked by remember { mutableStateOf(!lockEnabled) }
    if (lockEnabled) {
        val lifecycleOwner = LocalLifecycleOwner.current
        DisposableEffect(lifecycleOwner) {
            val obs = LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_STOP) unlocked = false
            }
            lifecycleOwner.lifecycle.addObserver(obs)
            onDispose { lifecycleOwner.lifecycle.removeObserver(obs) }
        }
        if (!unlocked) { LockScreen { unlocked = true }; return }
    }

    val sessions = remember { mutableStateListOf<TerminalHolder>() }
    var activeIndex by remember { mutableStateOf(-1) }   // -1 = no session in front
    // Wide screens only: the session shown beside the active one (-1 = no split).
    var splitIndex by remember { mutableStateOf(-1) }
    var route by remember { mutableStateOf(Route.Connect) }
    var sftpTarget by remember { mutableStateOf<SftpTarget?>(null) }
    var forwardSession by remember { mutableStateOf<cc.bsns.ssh.transport.ForwardSession?>(null) }
    var showForwards by remember { mutableStateOf(false) }
    // A tablet, a Chromebook, or an unfolded foldable gets the sidebar layout
    // (iPad parity); a phone or a narrow window keeps the bottom tabs.
    val wide = LocalConfiguration.current.screenWidthDp >= 840
    var sidebarOpen by remember { mutableStateOf(true) }

    /** Close a session. Closing one half of a split hands the screen to the other. */
    fun closeAt(i: Int) {
        val activeH = sessions.getOrNull(activeIndex)
        val splitH = sessions.getOrNull(splitIndex)
        val closed = sessions.removeAt(i).also { it.close() }
        val nextActive = if (closed === activeH) splitH else activeH
        splitIndex = if (closed !== activeH && closed !== splitH && splitH != null) sessions.indexOf(splitH) else -1
        activeIndex = when {
            sessions.isEmpty() -> -1
            nextActive != null -> sessions.indexOf(nextActive)
            else -> activeIndex.coerceAtMost(sessions.size - 1)   // closed the front one: its neighbour
        }
    }
    fun select(i: Int) { activeIndex = i; if (i == splitIndex) splitIndex = -1 }
    fun goTo(r: Route) { route = r; activeIndex = -1; splitIndex = -1 }
    fun openBeside(i: Int) {
        if (activeIndex !in sessions.indices || i == activeIndex) return
        splitIndex = i
        sidebarOpen = false   // two terminals need the width; the pane header brings it back
    }

    val fwd = forwardSession
    val target = sftpTarget
    val forwardsUp = showForwards && fwd != null
    val terminalUp = !forwardsUp && target == null && activeIndex in sessions.indices
    val split = wide && terminalUp && splitIndex in sessions.indices && splitIndex != activeIndex
    // The tab bar belongs to the top level only — never over a terminal, the file
    // browser, tunnels, or a pushed sub-screen — and wide screens use the sidebar.
    val showTabs = !wide && !forwardsUp && target == null && !terminalUp && route.parent == null

    // Keyboard shortcuts act on whatever is current when the key is pressed.
    val wideNow by rememberUpdatedState(wide)
    DisposableEffect(Unit) {
        AppShortcuts.handler = { action ->
            when (action) {
                AppShortcuts.Action.NewConnection -> {
                    sftpTarget = null; showForwards = false; goTo(Route.Connect); true
                }
                AppShortcuts.Action.CloseSession ->
                    if (activeIndex in sessions.indices) { closeAt(activeIndex); true } else false
                AppShortcuts.Action.NextSession, AppShortcuts.Action.PreviousSession -> {
                    if (sessions.isEmpty()) false else {
                        val step = if (action == AppShortcuts.Action.NextSession) 1 else -1
                        val from = if (activeIndex in sessions.indices) activeIndex else if (step > 0) -1 else 0
                        splitIndex = -1
                        activeIndex = (from + step + sessions.size) % sessions.size
                        true
                    }
                }
                AppShortcuts.Action.SplitBeside -> when {
                    !wideNow -> false
                    splitIndex >= 0 -> { splitIndex = -1; true }
                    sessions.size >= 2 && activeIndex in sessions.indices -> {
                        openBeside((activeIndex + 1) % sessions.size); true
                    }
                    else -> false
                }
                AppShortcuts.Action.ZoomIn -> sessions.getOrNull(activeIndex)?.zoom(1) != null
                AppShortcuts.Action.ZoomOut -> sessions.getOrNull(activeIndex)?.zoom(-1) != null
            }
        }
        onDispose { AppShortcuts.handler = null }
    }

    // Phones: the terminal pane carries its own tab strip (one compact header
    // row); the other screens show it above themselves so live sessions stay one
    // tap away. Wide screens list sessions in the sidebar instead.
    val sessionTabs: @Composable () -> Unit = {
        TabStrip(
            sessions = sessions,
            active = activeIndex,
            onSelect = { select(it) },
            onClose = { closeAt(it) },
            onNew = { activeIndex = -1; splitIndex = -1 },
        )
    }

    @Composable
    fun terminal(i: Int, focused: Boolean, leading: Boolean) {
        TerminalPane(
            sessions[i], showKeyBar = settings.showKeyBar,
            tabs = if (wide) {
                { PaneTitle(sessions[i], showSidebarButton = leading && !sidebarOpen) { sidebarOpen = true } }
            } else sessionTabs,
            focused = focused,
            // Touching the other pane of a split moves the keyboard (and "active") to it.
            onFocused = { if (i == splitIndex) { splitIndex = activeIndex; activeIndex = i } },
        ) { closeAt(i) }
    }

    @Composable
    fun content() {
        if (forwardsUp && fwd != null) {
            PortForwardsScreen(
                fwd,
                onStopAll = { fwd.close(); forwardSession = null; showForwards = false },
                onClose = { showForwards = false },
            )
        } else if (target != null) {
            SftpScreen(target) { sftpTarget = null }
        } else if (split) {
            // Two sessions side by side, in list order so focusing one never swaps them.
            val (left, right) = listOf(activeIndex, splitIndex).sorted()
            Row(Modifier.fillMaxSize()) {
                Box(Modifier.weight(1f)) { terminal(left, focused = left == activeIndex, leading = true) }
                // A real gutter: terminals draw edge to edge, so a hairline lets the
                // two panes' text run together.
                VerticalDivider(thickness = 6.dp, color = Brand.surface)
                Box(Modifier.weight(1f)) { terminal(right, focused = right == activeIndex, leading = false) }
            }
        } else if (terminalUp) {
            terminal(activeIndex, focused = true, leading = true)
        } else when (route) {
            Route.Connect -> ConnectScreen(
                form = connectForm,
                key = selectedKey,
                keys = keys,
                reloadKey = syncTick,
                onSelectKey = { selectedKeyId = it },
                onImport = { route = Route.Import },
                onSftp = { sftpTarget = it },
                forwardsActive = forwardSession != null,
                onReopenForwards = { showForwards = true },
                onForwards = { fs -> forwardSession?.close(); forwardSession = fs; showForwards = true },
            ) { session, title, factory ->
                val holder = TerminalHolder(context, session, title, factory,
                    fontSizeSp = settings.fontSize, scrollback = settings.scrollback,
                    keepAwake = settings.keepAwake, cursorBlink = settings.cursorBlink,
                    theme = Appearance.themeById(settings.theme), cursorStyle = settings.cursorStyle,
                    bellHaptic = settings.bellHaptic)
                sessions.add(holder)
                activeIndex = sessions.size - 1
                splitIndex = -1
                // Fire "run on connect" snippets once the shell has settled.
                val startup = SnippetStore(context).runOnConnect()
                if (startup.isNotEmpty()) main.postDelayed({
                    startup.forEach { holder.runSnippet(it.command) }
                }, 400)
            }
            // The other screens are forms and lists: keep them a readable width
            // on a big screen rather than stretched edge to edge.
            else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
                Box(Modifier.widthIn(max = 760.dp).fillMaxSize()) {
                    when (route) {
                        Route.Keys -> KeysScreen(keyManager) {
                            keys = keyManager.keys()
                            if (keys.none { it.id == selectedKeyId }) selectedKeyId = keys.first().id
                        }
                        Route.Settings -> SettingsScreen(
                            settings, biometricAvailable = biometricAvailable(context),
                            onBackup = { route = Route.Backup },
                            onSnippets = { route = Route.Snippets },
                            onHelp = { route = Route.Help },
                            onKnownHosts = { route = Route.Hosts },
                        )
                        Route.Hosts -> KnownHostsScreen { route = Route.Settings }
                        Route.Backup -> BackupScreen { route = Route.Settings }
                        Route.Snippets -> SnippetsScreen { route = Route.Settings }
                        Route.Help -> TerminalHelpScreen { route = Route.Settings }
                        // Returning recreates ConnectScreen, which reloads saved hosts from disk.
                        Route.Import -> ImportConfigScreen { route = Route.Connect }
                        Route.Connect -> Unit
                    }
                }
            }
        }
    }

    Scaffold(
        // Each screen pads for the system bars itself; with the tab bar up, its
        // height (incl. the navigation bar) is consumed below so nothing pads twice.
        contentWindowInsets = WindowInsets(0),
        bottomBar = {
            if (showTabs) {
                NavigationBar(containerColor = Brand.surface) {
                    Tab.entries.forEach { tab ->
                        NavigationBarItem(
                            selected = route.tab == tab,
                            onClick = { route = Route.root(tab) },
                            icon = { Icon(tab.icon, contentDescription = null) },
                            label = { Text(tab.label) },
                            colors = NavigationBarItemDefaults.colors(
                                selectedIconColor = Brand.accent,
                                selectedTextColor = Brand.accent,
                                indicatorColor = Brand.accent.copy(alpha = 0.16f),
                            ),
                        )
                    }
                }
            }
        },
    ) { pad ->
        if (wide) {
            Row(Modifier.fillMaxSize().padding(pad).consumeWindowInsets(pad).statusBarsPadding()) {
                // Off-screen panes (forwards/files) still need a way back to the sidebar.
                if (sidebarOpen || !terminalUp) {
                    Sidebar(
                        sessions = sessions,
                        current = if (terminalUp || forwardsUp || target != null) null else route.tab,
                        activeIndex = if (terminalUp) activeIndex else -1,
                        splitIndex = if (split) splitIndex else -1,
                        canHide = terminalUp,
                        onTab = { sftpTarget = null; showForwards = false; goTo(Route.root(it)) },
                        onSession = { sftpTarget = null; showForwards = false; select(it) },
                        onClose = { closeAt(it) },
                        onOpenBeside = { openBeside(it) },
                        onCloseSplit = { splitIndex = -1 },
                        onHide = { sidebarOpen = false },
                    )
                    VerticalDivider()
                }
                Box(Modifier.weight(1f).fillMaxHeight()) { content() }
            }
        } else {
            Column(Modifier.fillMaxSize().padding(pad).consumeWindowInsets(pad).statusBarsPadding()) {
                if (sessions.isNotEmpty() && !terminalUp) sessionTabs()
                Box(Modifier.fillMaxWidth().weight(1f)) { content() }
            }
        }
    }

    // Hardware Back navigates the hierarchy instead of exiting + dropping sessions.
    // Each handler only intercepts when there's somewhere to go back to; the bare
    // Connect tab (no session) leaves Back to its default (exit). Ordering mirrors
    // the visible-screen precedence above (forwards → sftp → session → route).
    // SFTP subfolder→up is handled inside SftpScreen's own BackHandler.
    BackHandler(enabled = forwardsUp) { showForwards = false }
    BackHandler(enabled = !forwardsUp && target != null) { sftpTarget = null }
    BackHandler(enabled = terminalUp) {
        // Leave a split first; otherwise back to Connect — the session stays alive.
        if (split) splitIndex = -1 else { activeIndex = -1; splitIndex = -1 }
    }
    BackHandler(enabled = !forwardsUp && target == null && !terminalUp && route != Route.Connect) {
        // A sub-screen returns to its parent; another tab's root returns to Connect.
        route = route.parent ?: Route.Connect
    }

    // Global overlay while a YubiKey (PIV) or FIDO2 operation waits for a tap/insert.
    // The overlay otherwise traps the user for the full tap timeout — Cancel aborts
    // the pending tap (YubiKeyManager.cancel / FidoKeyManager.cancel unblock the worker).
    (YubiKeyManager.awaitingTap ?: FidoKeyManager.awaitingTap)?.let { msg ->
        val cancelTap = {
            YubiKeyManager.cancel()
            FidoKeyManager.cancel()
        }
        AlertDialog(
            onDismissRequest = { cancelTap() },
            title = { Text("Security key") },
            text = { Text("$msg\n\nHold your key to the back of the phone (NFC) or plug it into USB-C.") },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { cancelTap() }) { Text("Cancel") } },
        )
    }
}

/** The wide-screen sidebar (iPad parity): the three destinations, then every live
 *  session with its status dot — tap to bring one forward, or open it beside the
 *  current one from its menu. */
@Composable
private fun Sidebar(
    sessions: List<TerminalHolder>,
    current: Tab?,
    activeIndex: Int,
    splitIndex: Int,
    canHide: Boolean,
    onTab: (Tab) -> Unit,
    onSession: (Int) -> Unit,
    onClose: (Int) -> Unit,
    onOpenBeside: (Int) -> Unit,
    onCloseSplit: () -> Unit,
    onHide: () -> Unit,
) {
    Column(
        Modifier.width(272.dp).fillMaxHeight().background(Brand.surface)
            .navigationBarsPadding().verticalScroll(rememberScrollState())
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Row(Modifier.fillMaxWidth().padding(start = 12.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("bsns.SSH", fontSize = 22.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            if (canHide) IconButton(onClick = onHide) { Icon(Icons.Outlined.ViewSidebar, "hide sidebar") }
        }
        val itemColors = NavigationDrawerItemDefaults.colors(
            unselectedContainerColor = Color.Transparent,
            selectedContainerColor = Brand.accent.copy(alpha = 0.16f),
            selectedIconColor = Brand.accent,
            selectedTextColor = Brand.accent,
        )
        Tab.entries.forEach { tab ->
            NavigationDrawerItem(
                label = { Text(tab.label) },
                icon = { Icon(tab.icon, contentDescription = null) },
                selected = current == tab,
                onClick = { onTab(tab) },
                colors = itemColors,
            )
        }
        if (sessions.isNotEmpty()) {
            Text("SESSIONS", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.6.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 6.dp))
            sessions.forEachIndexed { i, holder ->
                var menu by remember { mutableStateOf(false) }
                val (dot, state) = sessionState(holder)
                NavigationDrawerItem(
                    label = { Text(holder.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        fontFamily = FontFamily.Monospace, fontSize = 13.sp) },
                    icon = { Box(Modifier.semantics { stateDescription = state }) { StatusDot(dot) } },
                    selected = i == activeIndex || i == splitIndex,
                    onClick = { onSession(i) },
                    colors = itemColors,
                    badge = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box {
                                IconButton(onClick = { menu = true }, modifier = Modifier.size(32.dp)) {
                                    Icon(Icons.Default.MoreVert, "more for ${holder.title}", modifier = Modifier.size(18.dp))
                                }
                                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                    if (activeIndex >= 0 && i != activeIndex && i != splitIndex) {
                                        DropdownMenuItem(text = { Text("Open beside") },
                                            leadingIcon = { Icon(Icons.Outlined.VerticalSplit, null) },
                                            onClick = { menu = false; onOpenBeside(i) })
                                    }
                                    if (splitIndex >= 0) {
                                        DropdownMenuItem(text = { Text("Close split") },
                                            leadingIcon = { Icon(Icons.Outlined.CropSquare, null) },
                                            onClick = { menu = false; onCloseSplit() })
                                    }
                                    DropdownMenuItem(text = { Text("Disconnect") },
                                        leadingIcon = { Icon(Icons.AutoMirrored.Filled.Logout, null) },
                                        onClick = { menu = false; onClose(i) })
                                }
                            }
                        }
                    },
                )
            }
        }
    }
}

/** A wide-screen terminal pane's title: its status dot and user@host, plus the
 *  button that brings back a hidden sidebar. */
@Composable
private fun PaneTitle(holder: TerminalHolder, showSidebarButton: Boolean, onShowSidebar: () -> Unit) {
    val (dot, state) = sessionState(holder)
    Row(Modifier.padding(start = if (showSidebarButton) 2.dp else 14.dp), verticalAlignment = Alignment.CenterVertically) {
        if (showSidebarButton) IconButton(onClick = onShowSidebar) { Icon(Icons.Outlined.ViewSidebar, "show sidebar") }
        Box(Modifier.semantics { stateDescription = state }) { StatusDot(dot) }
        Text(holder.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
            fontFamily = FontFamily.Monospace, fontSize = 14.sp,
            modifier = Modifier.padding(start = 8.dp))
    }
}
