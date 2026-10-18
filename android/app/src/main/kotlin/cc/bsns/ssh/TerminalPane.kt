package cc.bsns.ssh

import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView

/** A session's connection state as a dot color + a TalkBack description:
 *  green live, amber reconnecting/stale, orange dropped (matches the iOS tab dots). */
internal fun sessionState(holder: TerminalHolder): Pair<Color, String> = when {
    holder.status == ConnStatus.Reconnecting -> Color(0xFFFFCC00) to "Reconnecting"
    holder.status == ConnStatus.Disconnected -> Color(0xFFFF9500) to "Disconnected"
    holder.isStale -> Color(0xFFFFCC00) to "Stale — no recent contact"
    else -> Color(0xFF34C759) to "Connected"
}

/** Session tabs: a capsule per session (status dot, user@host, close) plus "+" for
 *  a new connection. Scrolls sideways when there are more than fit. */
@Composable
fun TabStrip(
    sessions: List<TerminalHolder>,
    active: Int,
    onSelect: (Int) -> Unit,
    onClose: (Int) -> Unit,
    onNew: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        sessions.forEachIndexed { i, holder ->
            val sel = i == active
            val (dot, state) = sessionState(holder)
            // Capsule tab: active gets a brand-tinted fill + border, like the iOS session tabs.
            Row(
                Modifier.clip(CircleShape)
                    .background(
                        if (sel) MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)
                        else MaterialTheme.colorScheme.surfaceVariant,
                    )
                    .then(
                        if (sel) Modifier.border(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.6f), CircleShape)
                        else Modifier,
                    )
                    .clickable { onSelect(i) }
                    .padding(start = 12.dp, end = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.semantics { stateDescription = state }) { StatusDot(dot) }
                Spacer(Modifier.width(7.dp))
                Text(
                    // Keep user@host so root@db and deploy@db are distinguishable.
                    holder.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    fontFamily = FontFamily.Monospace, fontSize = 13.sp,
                    color = if (sel) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.widthIn(max = 180.dp),
                )
                IconButton(onClick = { onClose(i) }, modifier = Modifier.size(30.dp)) {
                    Icon(Icons.Default.Close, "close ${holder.title}", modifier = Modifier.size(14.dp),
                        tint = if (sel) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        IconButton(onClick = onNew, modifier = Modifier.size(34.dp)) {
            Icon(Icons.Default.Add, "new connection", modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
fun TerminalPane(
    holder: TerminalHolder,
    showKeyBar: Boolean = true,
    tabs: @Composable () -> Unit,
    // In a side-by-side split only one pane holds the keyboard; the other stays
    // put until touched, which reports it through onFocused.
    focused: Boolean = true,
    onFocused: () -> Unit = {},
    onDisconnect: () -> Unit,
) {
    var searching by remember { mutableStateOf(false) }
    var showSnippets by remember { mutableStateOf(false) }
    var showHistory by remember { mutableStateOf(false) }
    var showHelp by remember { mutableStateOf(false) }
    var showMenu by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    var hits by remember { mutableStateOf<List<Int>>(emptyList()) }
    var hitIdx by remember { mutableStateOf(0) }
    val findFocus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    // Read fresh each recomposition so a change in Settings takes effect on return.
    val (showTmuxKey, showScreenKey) = multiplexerButtons(SettingsStore(LocalContext.current).multiplexer)

    // When the search bar opens, take focus off the terminal View so the IME types
    // into the find field (a traditional View otherwise keeps Android focus), and
    // explicitly raise the soft keyboard — requestFocus alone doesn't always show it.
    LaunchedEffect(searching) {
        if (searching) { holder.terminalView.clearFocus(); findFocus.requestFocus(); keyboard?.show() }
    }
    DisposableEffect(holder) {
        onDispose { holder.setRemoteScrollMode(false) }
    }

    fun runSearch(q: String) {
        query = q
        hits = TerminalSearch.matches(holder.terminalView, q)
        hitIdx = hits.size - 1            // start at the most recent match
        if (hitIdx >= 0) TerminalSearch.scrollTo(holder.terminalView, hits[hitIdx])
    }
    fun step(delta: Int) {
        if (hits.isEmpty()) return
        hitIdx = (hitIdx + delta + hits.size) % hits.size
        TerminalSearch.scrollTo(holder.terminalView, hits[hitIdx])
    }
    fun closeSearch() {
        searching = false; query = ""; hits = emptyList()
        TerminalSearch.toBottom(holder.terminalView)
    }

    // Keep the key bar above whichever is taller: the keyboard, or (with it down)
    // the gesture/navigation bar — never underneath the home handle.
    Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.ime.union(WindowInsets.navigationBars))) {
        if (searching) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedTextField(
                    query, { runSearch(it) },
                    label = { Text("find") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { step(1) }),
                    modifier = Modifier.weight(1f).focusRequester(findFocus),
                )
                Text(
                    if (hits.isEmpty()) "0/0" else "${hitIdx + 1}/${hits.size}",
                    fontFamily = FontFamily.Monospace, fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 6.dp),
                )
                IconButton(onClick = { step(-1) }) { Icon(Icons.Default.KeyboardArrowUp, "previous match") }
                IconButton(onClick = { step(1) }) { Icon(Icons.Default.KeyboardArrowDown, "next match") }
                IconButton(onClick = { closeSearch() }) { Icon(Icons.Default.Close, "close search") }
            }
        } else {
            // One compact header row: the session tabs (each with its status dot)
            // take the space; the actions sit at the end, with the rarer ones —
            // help and disconnect — in the overflow menu.
            Row(Modifier.fillMaxWidth().padding(end = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { tabs() }
                // History/snippets act on the live session — disable when not
                // connected so they don't silently no-op. Find reads the local
                // buffer, so it stays available.
                val live = holder.status == ConnStatus.Connected
                IconButton(onClick = { showHistory = true }, enabled = live) { Icon(Icons.Default.History, "command history") }
                IconButton(onClick = { showSnippets = true }, enabled = live) { Icon(Icons.Default.Code, "snippets") }
                IconButton(onClick = { searching = true }) { Icon(Icons.Default.Search, "find") }
                Box {
                    IconButton(onClick = { showMenu = true }) { Icon(Icons.Default.MoreVert, "more") }
                    DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
                        DropdownMenuItem(
                            text = { Text("Terminal help") },
                            leadingIcon = { Icon(Icons.Outlined.Info, null) },
                            onClick = { showMenu = false; showHelp = true },
                        )
                        DropdownMenuItem(
                            text = { Text("Disconnect") },
                            leadingIcon = { Icon(Icons.AutoMirrored.Filled.Logout, null) },
                            onClick = { showMenu = false; onDisconnect() },
                        )
                    }
                }
            }
        }
        if (holder.status != ConnStatus.Connected) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    when {
                        holder.status == ConnStatus.Reconnecting -> "Reconnecting…"
                        holder.disconnectReason != null -> holder.disconnectReason!!
                        else -> "Disconnected"
                    },
                    fontSize = 13.sp, color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.weight(1f, fill = false).padding(end = 8.dp),
                )
                if (holder.status == ConnStatus.Disconnected) {
                    Button(onClick = { holder.reconnect() }) { Text("Reconnect") }
                }
            }
        } else if (holder.isStale) {
            // mosh stays "Connected" while it roams, but flag prolonged silence so a
            // dead session isn't shown as live (amber, not the error red). Offer a
            // Reconnect so a wedged session can be re-bootstrapped without dropping it.
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "mosh: no contact with the server — it may have dropped",
                    fontSize = 13.sp, color = Color(0xFFFFCC00),
                    modifier = Modifier.weight(1f, fill = false).padding(end = 8.dp),
                )
                Button(onClick = { holder.reconnect() }) { Text("Reconnect") }
            }
        }
        AndroidView(
            factory = { FrameLayout(it) },
            update = { container ->
                val v = holder.terminalView
                if (v.parent !== container) {
                    (v.parent as? ViewGroup)?.removeView(v)
                    container.removeAllViews()
                    container.addView(v)
                }
                v.setOnFocusChangeListener { _, has -> if (has) onFocused() }
                // Let the search field (or the other pane of a split) keep focus.
                // Posted, because a view that was only just attached can't take
                // focus yet — without it a hardware keyboard types into nothing
                // (or presses a focused button) until the terminal is tapped.
                if (!searching && focused && !v.hasFocus()) v.post { v.requestFocus() }
            },
            modifier = Modifier.weight(1f).fillMaxWidth()
                .semantics { contentDescription = "Terminal output" },
        )
        // Local autocomplete: chips from your own command history (no phone-home).
        // Only when connected — applying a completion writes to the live session, so
        // a dead session shouldn't offer chips that silently no-op.
        val suggestions = if (holder.status == ConnStatus.Connected)
            holder.suggestionsFor(holder.currentLine) else emptyList()
        if (suggestions.isNotEmpty()) {
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                suggestions.forEach { s ->
                    OutlinedButton(onClick = { holder.applyCompletion(s) },
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp)) {
                        Text(s, fontFamily = FontFamily.Monospace, fontSize = 12.sp, maxLines = 1)
                    }
                }
            }
        }
        if (showKeyBar) {
            KeyBar(
                remoteScrollActive = holder.remoteScrollActive,
                onKey = { holder.session.write(it) },
                onRemotePage = { up -> holder.sendRemoteScrollPage(up) },
                onEscape = { holder.finishRemoteScrollMode(sendEscape = true) },
                onTmuxCopy = {
                    if (holder.remoteScrollActive) {
                        holder.finishRemoteScrollMode(sendEscape = true)
                    } else {
                        holder.enterTmuxScrollMode()
                    }
                },
                onScreenCopy = {
                    if (holder.remoteScrollActive) {
                        holder.finishRemoteScrollMode(sendEscape = true)
                    } else {
                        holder.enterScreenScrollMode()
                    }
                },
                showTmux = showTmuxKey,
                showScreen = showScreenKey,
            )
        }
    }

    if (showSnippets) SnippetPickerDialog(
        onPick = { holder.runSnippet(it.command); showSnippets = false },
        onDismiss = { showSnippets = false },
    )

    if (showHistory) {
        val items = remember(showHistory) { holder.history() }
        AlertDialog(
            onDismissRequest = { showHistory = false },
            title = { Text("Command history") },
            text = {
                if (items.isEmpty()) Text("No history yet — run a few commands.", fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                else Column(Modifier.verticalScroll(rememberScrollState())) {
                    items.take(60).forEach { cmd ->
                        Text(cmd, fontFamily = FontFamily.Monospace, fontSize = 13.sp,
                            maxLines = 1,
                            modifier = Modifier.fillMaxWidth()
                                .clickable { holder.runSnippet(cmd); showHistory = false }
                                .padding(vertical = 6.dp))
                    }
                }
            },
            confirmButton = {
                if (items.isNotEmpty()) TextButton(onClick = { holder.clearHistory(); showHistory = false }) { Text("Clear") }
            },
            dismissButton = { TextButton(onClick = { showHistory = false }) { Text("Close") } },
        )
    }

    if (showHelp) {
        AlertDialog(
            onDismissRequest = { showHelp = false },
            title = { Text("Terminal Help") },
            text = {
                TerminalHelpContent(
                    Modifier.verticalScroll(rememberScrollState()),
                )
            },
            confirmButton = { TextButton(onClick = { showHelp = false }) { Text("Close") } },
        )
    }
}


private fun seq(vararg b: Int) = ByteArray(b.size) { b[it].toByte() }

/** Keys missing from soft keyboards but essential in a terminal. */
private data class KeyBarItem(val label: String, val action: () -> Unit)

@Composable
private fun KeyBar(
    remoteScrollActive: Boolean,
    onKey: (ByteArray) -> Unit,
    onRemotePage: (Boolean) -> Unit,
    onEscape: () -> Unit,
    onTmuxCopy: () -> Unit,
    onScreenCopy: () -> Unit,
    showTmux: Boolean = true,
    showScreen: Boolean = true,
) {
    val muxKeys = if (remoteScrollActive) {
        listOf(KeyBarItem("done", onTmuxCopy))
    } else {
        buildList {
            if (showTmux) add(KeyBarItem("tmux", onTmuxCopy))
            if (showScreen) add(KeyBarItem("screen", onScreenCopy))
        }
    }
    val keys = listOf(
        KeyBarItem("esc", onEscape),
        KeyBarItem("tab") { onKey(seq(0x09)) },
    ) + muxKeys + listOf(
        KeyBarItem("^C") { onKey(seq(0x03)) },
        KeyBarItem("^D") { onKey(seq(0x04)) },
        KeyBarItem("^Z") { onKey(seq(0x1A)) },
        KeyBarItem("^L") { onKey(seq(0x0C)) },
        KeyBarItem("←") { onKey(seq(0x1B, 0x5B, 0x44)) },
        KeyBarItem("↑") { onKey(seq(0x1B, 0x5B, 0x41)) },
        KeyBarItem("↓") { onKey(seq(0x1B, 0x5B, 0x42)) },
        KeyBarItem("→") { onKey(seq(0x1B, 0x5B, 0x43)) },
        KeyBarItem("⇞") {
            if (remoteScrollActive) onRemotePage(true) else onKey(seq(0x1B, 0x5B, 0x35, 0x7E))
        },
        KeyBarItem("⇟") {
            if (remoteScrollActive) onRemotePage(false) else onKey(seq(0x1B, 0x5B, 0x36, 0x7E))
        },
        KeyBarItem("|") { onKey(seq('|'.code)) },
        KeyBarItem("~") { onKey(seq('~'.code)) },
        KeyBarItem("/") { onKey(seq('/'.code)) },
        KeyBarItem("-") { onKey(seq('-'.code)) },
    )
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            .padding(horizontal = 6.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        keys.forEach { item ->
            // Rounded, filled key like the iOS key bar — a tappable chip, not a flat button.
            Box(
                Modifier.clip(RoundedCornerShape(8.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .clickable { item.action() }
                    .heightIn(min = 38.dp).widthIn(min = 42.dp)
                    .padding(horizontal = 12.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(item.label, fontFamily = FontFamily.Monospace, fontSize = 15.sp, fontWeight = FontWeight.Medium,
                    color = MaterialTheme.colorScheme.onSurface)
            }
        }
    }
}
