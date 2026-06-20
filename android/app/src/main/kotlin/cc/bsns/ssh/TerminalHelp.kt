package cc.bsns.ssh

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun TerminalHelpScreen(onBack: () -> Unit) {
    Scaffold { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(Spacing.screen)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(Spacing.section),
        ) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Terminal Help", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                TextButton(onClick = onBack) { Text("Done") }
            }
            TerminalHelpContent()
        }
    }
}

@Composable
fun TerminalHelpContent(modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Spacing.section)) {
        Section(title = "Scrolling") {
            HelpRow(
                title = "Normal scrollback",
                text = "In a regular shell, swipe or use scroll keys to move through local terminal scrollback.",
            )
            RowDivider()
            HelpRow(
                title = "Full-screen apps",
                text = "tmux, vim, less, and similar apps use the terminal's alternate screen. In that screen, local scrollback is not available; the remote app owns history.",
            )
        }

        Section(title = "Remote Scroll") {
            HelpRow(
                title = "Remote Scroll",
                text = "The hand/finger or tmux control switches panning from local scrollback to remote navigation keys.",
            )
            RowDivider()
            HelpRow(
                title = "tmux copy mode",
                text = "When you start scrolling in tmux, the app enters copy mode automatically. The shortcut bar shows done; tap it or press esc to leave.",
            )
            RowDivider()
            HelpRow(
                title = "Hardware keyboard",
                text = "Page Up and Page Down go to the remote app. Shift-Page Up and Shift-Page Down scroll local output when local scrollback is available.",
            )
        }

        Section(title = "Tools") {
            HelpRow(
                title = "Find",
                text = "Use Find from the terminal menu to search local scrollback. It does not search tmux history until tmux has printed that text into the terminal.",
            )
            RowDivider()
            HelpRow(
                title = "SFTP browser",
                text = "Use Browse files from a host to upload or download files over SFTP.",
            )
        }
    }
}

@Composable
private fun HelpRow(title: String, text: String) {
    Column(Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
        Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Text(
            text,
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}
