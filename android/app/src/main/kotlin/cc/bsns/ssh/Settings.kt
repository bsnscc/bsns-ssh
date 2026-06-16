package cc.bsns.ssh

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Divider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
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
}

@Composable
private fun SettingToggle(label: String, value: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 15.sp,
            color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
        Switch(checked = value, onCheckedChange = onChange, enabled = enabled)
    }
}

/** Settings: terminal appearance/behaviour + the app-lock toggle. */
@Composable
fun SettingsScreen(store: SettingsStore, biometricAvailable: Boolean, onBackup: () -> Unit, onSnippets: () -> Unit, onBack: () -> Unit) {
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
    val scrollbackOptions = listOf(500, 1000, 2000, 5000, 10000)
    val themeIds = Appearance.themes.map { it.id }

    Scaffold { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                Text("Settings", fontFamily = FontFamily.Monospace, fontSize = 20.sp)
                TextButton(onClick = onBack) { Text("Done") }
            }
            Text("Changes apply to new sessions.", fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant)

            Divider()
            Text("Terminal", fontSize = 13.sp, color = MaterialTheme.colorScheme.primary)

            Row(Modifier.fillMaxWidth().padding(vertical = 6.dp),
                horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text("Font size", fontSize = 15.sp)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedButton(onClick = {
                        if (fontSize > 8) { fontSize--; store.fontSize = fontSize }
                    }) { Text("–") }
                    Text("$fontSize", fontFamily = FontFamily.Monospace, fontSize = 15.sp,
                        modifier = Modifier.padding(horizontal = 14.dp))
                    OutlinedButton(onClick = {
                        if (fontSize < 30) { fontSize++; store.fontSize = fontSize }
                    }) { Text("+") }
                }
            }

            Row(Modifier.fillMaxWidth().clickable {
                val next = scrollbackOptions[(scrollbackOptions.indexOf(scrollback).coerceAtLeast(0) + 1) % scrollbackOptions.size]
                scrollback = next; store.scrollback = next
            }.padding(vertical = 6.dp), horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                Text("Scrollback", fontSize = 15.sp)
                Text("$scrollback lines", fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                    color = MaterialTheme.colorScheme.primary)
            }

            Row(Modifier.fillMaxWidth().clickable {
                val next = themeIds[(themeIds.indexOf(theme).coerceAtLeast(0) + 1) % themeIds.size]
                theme = next; store.theme = next
            }.padding(vertical = 6.dp), horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                Text("Theme", fontSize = 15.sp)
                Text(theme, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                    color = MaterialTheme.colorScheme.primary)
            }

            Row(Modifier.fillMaxWidth().clickable {
                val next = Appearance.cursorStyles[(Appearance.cursorStyles.indexOf(cursorStyle).coerceAtLeast(0) + 1) % Appearance.cursorStyles.size]
                cursorStyle = next; store.cursorStyle = next
            }.padding(vertical = 6.dp), horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                Text("Cursor shape", fontSize = 15.sp)
                Text(cursorStyle, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                    color = MaterialTheme.colorScheme.primary)
            }

            SettingToggle("Cursor blink", cursorBlink) { cursorBlink = it; store.cursorBlink = it }
            SettingToggle("Bell vibrates (haptic)", bellHaptic) { bellHaptic = it; store.bellHaptic = it }
            SettingToggle("Keep screen awake while connected", keepAwake) { keepAwake = it; store.keepAwake = it }
            SettingToggle("Show key bar", showKeyBar) { showKeyBar = it; store.showKeyBar = it }

            Divider()
            Text("Security", fontSize = 13.sp, color = MaterialTheme.colorScheme.primary)
            SettingToggle(
                if (biometricAvailable) "Require fingerprint / face to unlock"
                else "Require fingerprint / face (none enrolled)",
                appLock, enabled = biometricAvailable,
            ) {
                appLock = it; store.appLock = it
                // Apply screenshot/recents protection NOW, not on the next resume.
                (context as? android.app.Activity)?.let { a -> applySecureFlag(a.window, it) }
            }
            SettingToggle("Record command history (on device)", commandHistory) {
                commandHistory = it; store.commandHistory = it
            }
            Text("History stays on this device and is never synced. Type a command with a " +
                "leading space to keep that one out of history.",
                fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

            Divider()
            Text("Snippets", fontSize = 13.sp, color = MaterialTheme.colorScheme.primary)
            OutlinedButton(onClick = onSnippets) { Text("Manage snippets") }

            Divider()
            Text("Backup", fontSize = 13.sp, color = MaterialTheme.colorScheme.primary)
            OutlinedButton(onClick = onBackup) { Text("Export / import (encrypted)") }

            Divider()
            Text(
                "No accounts. No analytics. No telemetry. Your keys stay on this device; " +
                    "the device key lives in the Android Keystore and can never be exported " +
                    "(see Keys for whether it's StrongBox- or TEE-backed on your hardware).",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp),
            )

            Divider()
            Text("About", fontSize = 13.sp, color = MaterialTheme.colorScheme.primary)
            val info = remember {
                runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull()
            }
            val versionName = info?.versionName ?: "?"
            val versionCode = info?.let {
                if (android.os.Build.VERSION.SDK_INT >= 28) it.longVersionCode else it.versionCode.toLong()
            } ?: 0L
            Text("bsns.\$_  ·  version $versionName (build $versionCode)",
                fontFamily = FontFamily.Monospace, fontSize = 13.sp)
            Text("GPLv3 · OpenSSL 3.5 + libssh2, built from source",
                fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
