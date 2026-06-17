package cc.bsns.ssh

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Shared UI primitives that give the Android app the grouped, consistent look of
 * the iOS Form/Section design — expressed in native Material (rounded surface
 * "cards", brand-tinted), not a literal iOS clone. Use these instead of hand-laid
 * Column + Divider so every screen reads as one design system.
 */
object Spacing {
    val screen = 16.dp        // screen content inset
    val section = 22.dp       // gap between sections
    val cardCorner = 14.dp    // section-card corner radius
    val rowMinHeight = 48.dp  // comfortable tap target per row
}

/** A grouped section: optional header label, a rounded card holding the rows, and
 *  an optional footer caption — the Android equivalent of an iOS Form Section. */
@Composable
fun Section(
    title: String? = null,
    footer: String? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        title?.let {
            Text(
                it.uppercase(),
                fontSize = 12.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.6.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 6.dp, bottom = 7.dp),
            )
        }
        Surface(
            color = MaterialTheme.colorScheme.surfaceVariant,
            shape = RoundedCornerShape(Spacing.cardCorner),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 4.dp), content = content)
        }
        footer?.let {
            Text(
                it, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 6.dp, end = 6.dp, top = 7.dp),
            )
        }
    }
}

/** A thin inset separator between rows in a Section (like iOS Form row separators). */
@Composable
fun RowDivider() {
    HorizontalDivider(color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.15f))
}

/** A labeled row inside a Section: label left, trailing control right. Pass
 *  `onClick` for a tappable row (e.g. cycle-through settings). */
@Composable
fun SettingRow(
    label: String,
    enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
    trailing: @Composable () -> Unit,
) {
    val base = Modifier.fillMaxWidth().heightIn(min = Spacing.rowMinHeight)
    val m = if (onClick != null) base.clickable(enabled = enabled, onClick = onClick) else base
    Row(
        m.padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label, fontSize = 15.sp,
            color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        trailing()
    }
}

/** A small colored status dot (connection state) — matches the iOS dots. */
@Composable
fun StatusDot(color: Color, size: Dp = 8.dp) {
    Box(Modifier.size(size).clip(CircleShape).background(color))
}

/** A capsule tag (e.g. "mosh", "via jump") — colored text on a tinted capsule. */
@Composable
fun CapsuleTag(text: String, color: Color) {
    Text(
        text, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = color,
        modifier = Modifier.clip(CircleShape).background(color.copy(alpha = 0.18f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}
