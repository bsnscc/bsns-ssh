package cc.bsns.ssh

import androidx.compose.ui.graphics.Color
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TextStyle

/** The one source of truth for brand color — sampled from the bsns.$_ app icon
 *  (#00C29C on #0F0F0F). Drives the Material color scheme, active states, and the
 *  terminal `bsns Dark` theme, so chrome + terminal match the icon and the iOS app
 *  (kept identical hex to the iOS `Brand`). */
object Brand {
    val accent = Color(0xFF00C29C)
    val nearBlack = Color(0xFF0F0F0F)
    val surface = Color(0xFF1A1A1A)
    val foreground = Color(0xFFE8E8E8)
}

/** A terminal colour preset (ARGB) — background, foreground, cursor. */
class TerminalTheme(val id: String, val bg: Int, val fg: Int, val cursor: Int)

/** Terminal appearance: colour themes + cursor shape, applied to the emulator. */
object Appearance {
    val themes = listOf(
        TerminalTheme("bsns Dark", 0xFF0F0F0F.toInt(), 0xFFE8E8E8.toInt(), 0xFF00C29C.toInt()),
        TerminalTheme("Solarized Dark", 0xFF002B36.toInt(), 0xFF839496.toInt(), 0xFF93A1A1.toInt()),
        TerminalTheme("Dracula", 0xFF282A36.toInt(), 0xFFF8F8F2.toInt(), 0xFFF8F8F0.toInt()),
    )

    fun themeById(id: String): TerminalTheme = themes.firstOrNull { it.id == id } ?: themes[0]

    /** Override the emulator's default bg/fg/cursor with the theme. */
    fun apply(emu: TerminalEmulator, theme: TerminalTheme) {
        emu.mColors.mCurrentColors[TextStyle.COLOR_INDEX_BACKGROUND] = theme.bg
        emu.mColors.mCurrentColors[TextStyle.COLOR_INDEX_FOREGROUND] = theme.fg
        emu.mColors.mCurrentColors[TextStyle.COLOR_INDEX_CURSOR] = theme.cursor
    }

    val cursorStyles = listOf("block", "underline", "bar")

    /** DECSCUSR for the steady cursor shape (blink is the view's blinker, so use
     *  the steady variant to avoid the two fighting): `ESC [ Ps SP q`. */
    fun cursorStyleEscape(style: String): ByteArray {
        val n: Byte = when (style) {
            "underline" -> '4'.code.toByte()
            "bar" -> '6'.code.toByte()
            else -> '2'.code.toByte()
        }
        return byteArrayOf(0x1B, '['.code.toByte(), n, ' '.code.toByte(), 'q'.code.toByte())
    }
}
