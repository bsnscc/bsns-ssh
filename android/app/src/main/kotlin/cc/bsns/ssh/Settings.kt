package cc.bsns.ssh

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** App preferences (SharedPreferences). The terminal layer reads these at session
 *  creation; the key bar reads `showKeyBar` live. Mirrors the iOS `AppSettings`. */
class SettingsStore(context: Context) {
    private val p = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    var fontSize: Int
        get() = p.getInt("fontSize", 15); set(v) { p.edit().putInt("fontSize", v).apply() }
    var scrollback: Int
        get() = p.getInt("scrollback", 2000); set(v) { p.edit().putInt("scrollback", v).apply() }
    var keepAwake: Boolean
        get() = p.getBoolean("keepAwake", false); set(v) { p.edit().putBoolean("keepAwake", v).apply() }
    var showKeyBar: Boolean
        get() = p.getBoolean("showKeyBar", true); set(v) { p.edit().putBoolean("showKeyBar", v).apply() }
    var cursorBlink: Boolean
        get() = p.getBoolean("cursorBlink", true); set(v) { p.edit().putBoolean("cursorBlink", v).apply() }
    var appLock: Boolean
        get() = p.getBoolean("appLock", false); set(v) { p.edit().putBoolean("appLock", v).apply() }
    var theme: String
        get() = p.getString("theme", "bsns Dark") ?: "bsns Dark"; set(v) { p.edit().putString("theme", v).apply() }
    var cursorStyle: String
        get() = p.getString("cursorStyle", "block") ?: "block"; set(v) { p.edit().putString("cursorStyle", v).apply() }
    var bellHaptic: Boolean
        get() = p.getBoolean("bellHaptic", true); set(v) { p.edit().putBoolean("bellHaptic", v).apply() }
    var commandHistory: Boolean
        get() = p.getBoolean("commandHistory", true); set(v) { p.edit().putBoolean("commandHistory", v).apply() }
    var tmuxScrollSequence: String
        get() = p.getString("tmuxScrollSequence", "C-b [") ?: "C-b ["
        set(v) { p.edit().putString("tmuxScrollSequence", v).apply() }
    var screenScrollSequence: String
        get() = p.getString("screenScrollSequence", "C-a [") ?: "C-a ["
        set(v) { p.edit().putString("screenScrollSequence", v).apply() }
    /** How long a mosh-server keeps running with no client before it exits on its
     *  own (hours; 0 = never). The backstop for servers the reap-on-connect pass
     *  misses — see MoshBootstrap. */
    var moshIdleTimeoutHours: Int
        get() = p.getInt("moshIdleTimeoutHours", MoshBootstrap.DEFAULT_IDLE_TIMEOUT_HOURS)
        set(v) { p.edit().putInt("moshIdleTimeoutHours", v).apply() }
    /** Which copy/scroll buttons to show: "both", "tmux", or "screen". */
    var multiplexer: String
        get() = p.getString("multiplexer", "both") ?: "both"
        set(v) { p.edit().putString("multiplexer", v).apply() }
}

val multiplexerOptions = listOf("both", "tmux", "screen")

/** Resolve the multiplexer preference to (showTmux, showScreen). */
fun multiplexerButtons(pref: String): Pair<Boolean, Boolean> = when (pref) {
    "tmux" -> true to false
    "screen" -> false to true
    else -> true to true
}

/** Font-size bounds shared by the Settings stepper and pinch-to-zoom. */
const val MIN_FONT_SP = 8
const val MAX_FONT_SP = 30

@Composable
private fun SettingToggle(label: String, value: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    SettingRow(label, enabled) {
        Switch(checked = value, onCheckedChange = onChange, enabled = enabled)
    }
}

/** A row showing the current value; tapping opens a menu of the choices. */
@Composable
private fun <T> ChoiceRow(label: String, value: T, options: List<T>, display: (T) -> String = { it.toString() }, onPick: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    SettingRow(label, onClick = { open = true }) {
        Box {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(display(value), fontSize = 14.sp, color = MaterialTheme.colorScheme.primary)
                Icon(Icons.Default.UnfoldMore, contentDescription = null, modifier = Modifier.size(18.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                options.forEach { o ->
                    DropdownMenuItem(
                        text = { Text(display(o)) },
                        trailingIcon = { if (o == value) Icon(Icons.Default.Check, contentDescription = "selected") },
                        onClick = { open = false; onPick(o) },
                    )
                }
            }
        }
    }
}

/** A row that opens another screen. */
@Composable
private fun NavRow(label: String, detail: String? = null, onClick: () -> Unit) {
    SettingRow(label, onClick = onClick) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            detail?.let { Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Settings: terminal appearance/behaviour, sessions, security, and the tools
 *  (snippets, backup, help) — grouped like the iOS Settings tab. */
@Composable
fun SettingsScreen(
    store: SettingsStore,
    biometricAvailable: Boolean,
    onBackup: () -> Unit,
    onSnippets: () -> Unit,
    onHelp: () -> Unit,
    onKnownHosts: () -> Unit,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var fontSize by remember { mutableStateOf(store.fontSize) }
    var scrollback by remember { mutableStateOf(store.scrollback) }
    var keepAwake by remember { mutableStateOf(store.keepAwake) }
    var showKeyBar by remember { mutableStateOf(store.showKeyBar) }
    var cursorBlink by remember { mutableStateOf(store.cursorBlink) }
    var appLock by remember { mutableStateOf(store.appLock) }
    var commandHistory by remember { mutableStateOf(store.commandHistory) }
    var theme by remember { mutableStateOf(store.theme) }
    var cursorStyle by remember { mutableStateOf(store.cursorStyle) }
    var bellHaptic by remember { mutableStateOf(store.bellHaptic) }
    var tmuxScrollSequence by remember { mutableStateOf(store.tmuxScrollSequence) }
    var screenScrollSequence by remember { mutableStateOf(store.screenScrollSequence) }
    var multiplexer by remember { mutableStateOf(store.multiplexer) }
    var moshIdleHours by remember { mutableStateOf(store.moshIdleTimeoutHours) }
    val scrollbackOptions = listOf(500, 1000, 2000, 5000, 10000)
    val moshIdleOptions = listOf(0, 1, 4, 12, 24, 72)

    Scaffold { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(horizontal = Spacing.screen).verticalScroll(rememberScrollState())
                .padding(bottom = Spacing.screen),
            verticalArrangement = Arrangement.spacedBy(Spacing.section),
        ) {
            ScreenTitle("Settings")

            Section(title = "Appearance", footer = "Pinch the terminal to zoom; the size you land on becomes the default.") {
                ChoiceRow("Theme", theme, Appearance.themes.map { it.id }) { theme = it; store.theme = it }
                RowDivider()
                SettingRow("Font size") {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        IconButton(enabled = fontSize > MIN_FONT_SP,
                            onClick = { fontSize--; store.fontSize = fontSize }) { Icon(Icons.Default.Remove, "smaller") }
                        Text("$fontSize", fontFamily = FontFamily.Monospace, fontSize = 15.sp,
                            modifier = Modifier.widthIn(min = 28.dp), textAlign = TextAlign.Center)
                        IconButton(enabled = fontSize < MAX_FONT_SP,
                            onClick = { fontSize++; store.fontSize = fontSize }) { Icon(Icons.Default.Add, "larger") }
                    }
                }
                RowDivider()
                ChoiceRow("Cursor", cursorStyle, Appearance.cursorStyles) { cursorStyle = it; store.cursorStyle = it }
                RowDivider()
                SettingToggle("Cursor blink", cursorBlink) { cursorBlink = it; store.cursorBlink = it }
            }

            Section(title = "Terminal", footer = "Changes apply to new sessions.") {
                ChoiceRow("Scrollback", scrollback, scrollbackOptions, { "$it lines" }) { scrollback = it; store.scrollback = it }
                RowDivider()
                SettingToggle("Shortcut bar", showKeyBar) { showKeyBar = it; store.showKeyBar = it }
                RowDivider()
                SettingToggle("Vibrate on bell", bellHaptic) { bellHaptic = it; store.bellHaptic = it }
                RowDivider()
                SettingToggle("Keep screen awake", keepAwake) { keepAwake = it; store.keepAwake = it }
            }

            Section(
                title = "Sessions",
                footer = "A mosh session keeps running on the host while you're away — that's what lets it resume. " +
                    "This is the backstop for ones the app can no longer reach, so they don't pile up.",
            ) {
                ChoiceRow("Expire idle mosh sessions", moshIdleHours, moshIdleOptions, {
                    when {
                        it == 0 -> "never"
                        it < 24 -> "${it}h"
                        else -> "${it / 24}d"
                    }
                }) { moshIdleHours = it; store.moshIdleTimeoutHours = it }
            }

            Section(
                title = "Multiplexer scroll",
                footer = "The keys that enter copy mode in a running session — e.g. C-b [, C-a [, Esc [. " +
                    "Tokens can be C-x, Ctrl-x, Esc, Tab, Enter, Space, 0x1b, or literal text.",
            ) {
                ChoiceRow("Show buttons for", multiplexer, multiplexerOptions) { multiplexer = it; store.multiplexer = it }
                RowDivider()
                FormField("tmux", tmuxScrollSequence, { tmuxScrollSequence = it; store.tmuxScrollSequence = it },
                    placeholder = "C-b [", description = "tmux copy-mode sequence")
                RowDivider()
                FormField("screen", screenScrollSequence, { screenScrollSequence = it; store.screenScrollSequence = it },
                    placeholder = "C-a [", description = "screen copy-mode sequence")
            }

            Section(
                title = "Security",
                footer = "History stays on this device and is never synced. Start a command with a space to keep it out.",
            ) {
                SettingToggle(
                    if (biometricAvailable) "Unlock with fingerprint / face" else "Unlock with biometrics (none enrolled)",
                    appLock, enabled = biometricAvailable,
                ) {
                    appLock = it; store.appLock = it
                    // Apply screenshot/recents protection NOW, not on the next resume.
                    (context as? android.app.Activity)?.let { a -> applySecureFlag(a.window, it) }
                }
                RowDivider()
                SettingToggle("Command history (on device)", commandHistory) {
                    commandHistory = it; store.commandHistory = it
                }
                RowDivider()
                NavRow("Known hosts", onClick = onKnownHosts)
            }

            Section(title = "Tools") {
                NavRow("Snippets", onClick = onSnippets)
                RowDivider()
                NavRow("Backup & sync", detail = "encrypted", onClick = onBackup)
                RowDivider()
                NavRow("Terminal help", onClick = onHelp)
            }

            val info = remember {
                runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull()
            }
            val versionName = info?.versionName ?: "?"
            val versionCode = info?.let {
                if (android.os.Build.VERSION.SDK_INT >= 28) it.longVersionCode else it.versionCode.toLong()
            } ?: 0L
            Section(
                title = "About",
                footer = "No accounts. No analytics. No telemetry. Your keys stay on this device; the device key lives in the Android Keystore and can never be exported.",
            ) {
                SettingRow("Version") {
                    Text("$versionName ($versionCode)", fontFamily = FontFamily.Monospace, fontSize = 13.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                RowDivider()
                SettingRow("License") {
                    Text("GPLv3 · OpenSSL 3.5 + libssh2", fontSize = 13.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}
