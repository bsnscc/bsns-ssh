package cc.bsns.ssh

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** A reusable command (or command sequence). `runOnConnect` snippets are sent
 *  automatically into each new session right after it opens. */
data class Snippet(val id: String, val name: String, val command: String, val runOnConnect: Boolean = false)

/** Persists snippets in SharedPreferences as a JSON array (no extra deps). */
class SnippetStore(context: Context) {
    private val prefs = context.getSharedPreferences("snippets", Context.MODE_PRIVATE)

    fun load(): List<Snippet> = try {
        val arr = JSONArray(prefs.getString("list", "[]"))
        (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            Snippet(o.optString("id", UUID.randomUUID().toString()),
                o.getString("name"), o.getString("command"), o.optBoolean("runOnConnect", false))
        }
    } catch (e: Exception) {
        emptyList()
    }

    private fun save(list: List<Snippet>) {
        val arr = JSONArray()
        list.forEach {
            arr.put(JSONObject().put("id", it.id).put("name", it.name)
                .put("command", it.command).put("runOnConnect", it.runOnConnect))
        }
        prefs.edit().putString("list", arr.toString()).commit()
    }

    fun upsert(s: Snippet): List<Snippet> {
        val list = load().toMutableList()
        val i = list.indexOfFirst { it.id == s.id }
        if (i >= 0) list[i] = s else list.add(s)
        save(list); return list
    }

    fun remove(id: String): List<Snippet> = load().filter { it.id != id }.also { save(it) }

    fun runOnConnect(): List<Snippet> = load().filter { it.runOnConnect }
}

/** Manage snippets: add / edit / delete, and flag which run automatically on connect. */
@Composable
fun SnippetsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val store = remember { SnippetStore(context) }
    var snippets by remember { mutableStateOf(store.load()) }
    var editing by remember { mutableStateOf<Snippet?>(null) }   // the snippet being added/edited
    var confirmDelete by remember { mutableStateOf<Snippet?>(null) }

    Scaffold { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                Text("Snippets", fontFamily = FontFamily.Monospace, fontSize = 20.sp)
                TextButton(onClick = onBack) { Text("Done") }
            }
            Text("Reusable commands. Tap the ⌗ button in a session to run one. " +
                "\"Run on connect\" snippets are sent automatically when a session opens.",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

            snippets.forEach { s ->
                HorizontalDivider()
                Row(Modifier.fillMaxWidth().clickable { editing = s }.padding(vertical = 6.dp),
                    horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(s.name + if (s.runOnConnect) "  · on connect" else "",
                            fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                            color = MaterialTheme.colorScheme.primary)
                        Text(s.command.lines().firstOrNull().orEmpty().take(48),
                            fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    IconButton(onClick = { confirmDelete = s }, modifier = Modifier.size(48.dp)) {
                        Icon(Icons.Default.Close, contentDescription = "Delete snippet ${s.name}",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            HorizontalDivider()
            Button(onClick = { editing = Snippet(UUID.randomUUID().toString(), "", "") }) { Text("New snippet") }
        }
    }

    confirmDelete?.let { s ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text("Delete snippet?") },
            text = { Text("Delete the snippet \"${s.name}\"? This can't be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    snippets = store.remove(s.id); confirmDelete = null
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("Cancel") } },
        )
    }

    editing?.let { snip ->
        var name by remember(snip) { mutableStateOf(snip.name) }
        var command by remember(snip) { mutableStateOf(snip.command) }
        var onConnect by remember(snip) { mutableStateOf(snip.runOnConnect) }
        AlertDialog(
            onDismissRequest = { editing = null },
            title = { Text(if (snip.name.isEmpty()) "New snippet" else "Edit snippet") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(name, { name = it }, label = { Text("name") },
                        singleLine = true, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(command, { command = it }, label = { Text("command(s)") },
                        modifier = Modifier.fillMaxWidth())
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically) {
                        Text("Run on connect", fontSize = 14.sp)
                        Switch(checked = onConnect, onCheckedChange = { onConnect = it })
                    }
                }
            },
            confirmButton = {
                TextButton(enabled = name.isNotBlank() && command.isNotBlank(), onClick = {
                    snippets = store.upsert(snip.copy(name = name.trim(), command = command, runOnConnect = onConnect))
                    editing = null
                }) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = { editing = null }) { Text("Cancel") } },
        )
    }
}

/** A picker shown over a live session: tap a snippet to send it to the terminal. */
@Composable
fun SnippetPickerDialog(onPick: (Snippet) -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val snippets = remember { SnippetStore(context).load() }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Run a snippet") },
        text = {
            if (snippets.isEmpty()) {
                Text("No snippets yet. Add some under Snippets.", fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else Column(Modifier.verticalScroll(rememberScrollState())) {
                snippets.forEach { s ->
                    Column(Modifier.fillMaxWidth().clickable { onPick(s) }.padding(vertical = 8.dp)) {
                        Text(s.name, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                            color = MaterialTheme.colorScheme.primary)
                        Text(s.command.lines().firstOrNull().orEmpty().take(48),
                            fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
}
