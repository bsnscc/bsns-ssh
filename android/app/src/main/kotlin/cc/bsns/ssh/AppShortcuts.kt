package cc.bsns.ssh

import android.view.KeyEvent
import android.view.KeyboardShortcutGroup
import android.view.KeyboardShortcutInfo

/**
 * Hardware-keyboard shortcuts for a tablet, Chromebook, or desktop-mode phone.
 * Every one is Ctrl+Shift+key, so the terminal keeps each plain Ctrl chord for
 * the shell (Ctrl+W, Ctrl+T, Ctrl+D all mean something there). The activity
 * routes key events here before any view sees them, and lists the shortcuts in
 * the system's keyboard-shortcut helper (Meta+/).
 */
object AppShortcuts {
    enum class Action(val label: String, val keyCode: Int) {
        NewConnection("New connection", KeyEvent.KEYCODE_T),
        CloseSession("Close session", KeyEvent.KEYCODE_W),
        NextSession("Next session", KeyEvent.KEYCODE_RIGHT_BRACKET),
        PreviousSession("Previous session", KeyEvent.KEYCODE_LEFT_BRACKET),
        SplitBeside("Open beside / close split", KeyEvent.KEYCODE_D),
        ZoomIn("Zoom in", KeyEvent.KEYCODE_EQUALS),
        ZoomOut("Zoom out", KeyEvent.KEYCODE_MINUS),
    }

    /** Set by the UI while it's composed; returns whether the action applied. */
    var handler: ((Action) -> Boolean)? = null

    fun dispatch(event: KeyEvent): Boolean {
        if (event.action != KeyEvent.ACTION_DOWN) return false
        if (!event.isCtrlPressed || !event.isShiftPressed || event.isAltPressed || event.isMetaPressed) return false
        val action = Action.entries.firstOrNull { it.keyCode == event.keyCode } ?: return false
        // Consume a recognised chord even when it has nothing to act on (e.g. "open
        // beside" with one session): passed through, the terminal would send it as
        // the plain control character — Ctrl+Shift+D would log the shell out.
        handler?.invoke(action)
        return true
    }

    fun group(): KeyboardShortcutGroup = KeyboardShortcutGroup(
        "Sessions",
        Action.entries.map {
            KeyboardShortcutInfo(it.label, it.keyCode, KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON)
        },
    )
}
