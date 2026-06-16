package cc.bsns.ssh

import com.termux.view.TerminalView

/**
 * Find-in-scrollback over a Termux [TerminalView]: scans the buffer (history +
 * screen) line by line for a case-insensitive substring and scrolls matches into
 * view. Row indices are the emulator's own (negative = scrollback history, 0… =
 * live screen); `mTopRow` selects the top visible row. Mirrors the iOS find.
 */
object TerminalSearch {
    /** Absolute row indices containing `query` (oldest → newest). */
    fun matches(view: TerminalView, query: String): List<Int> {
        val emu = view.mEmulator ?: return emptyList()
        if (query.isEmpty()) return emptyList()
        val buf = emu.screen
        val cols = emu.mColumns
        val top = -buf.activeTranscriptRows
        val bottom = emu.mRows - 1
        val q = query.lowercase()
        val out = ArrayList<Int>()
        for (r in top..bottom) {
            val line = buf.getSelectedText(0, r, cols, r + 1) ?: continue
            if (line.lowercase().contains(q)) out.add(r)
        }
        return out
    }

    /** Scroll so `row` sits near the top of the view (clamped to the scrollback).
     *  Uses invalidate(), NOT onScreenUpdated() — the latter auto-scrolls back to
     *  the bottom (resets mTopRow to 0). */
    fun scrollTo(view: TerminalView, row: Int) {
        val emu = view.mEmulator ?: return
        val minTop = -emu.screen.activeTranscriptRows
        view.topRow = (row - 1).coerceIn(minTop, 0)
        view.invalidate()
    }

    /** Return to the live screen (bottom). */
    fun toBottom(view: TerminalView) {
        view.topRow = 0
        view.invalidate()
    }
}
