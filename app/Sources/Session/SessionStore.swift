import Observation

/// Holds every live terminal session and which one is on screen. A nil `activeID`
/// means no terminal is shown — the Connect / Keys tabs are. Closing a session
/// disconnects it and falls back to another (or home).
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [TerminalSession] = []
    var activeID: TerminalSession.ID?

    /// Persists open sessions for auto-reconnect after an iOS background kill.
    /// Wired once at launch; a session is remembered on add and forgotten on close,
    /// so the file always mirrors what's currently open.
    var restore: SessionRestoreStore?

    var active: TerminalSession? { sessions.first { $0.id == activeID } }

    /// Two sessions shown side by side on a wide screen: left, then right. The
    /// active one is whichever has the keyboard. Nil when one session fills
    /// the space.
    private(set) var pair: [TerminalSession.ID]?

    /// The two sessions to show side by side right now, if a split is set up
    /// and the active session is part of it.
    var splitSessions: [TerminalSession]? {
        guard let pair, let activeID, pair.contains(activeID) else { return nil }
        let both = pair.compactMap { id in sessions.first { $0.id == id } }
        return both.count == 2 ? both : nil
    }

    /// Show `other` beside the active session (which stays on the left).
    func split(with other: TerminalSession) {
        guard let activeID, activeID != other.id else { return }
        pair = [activeID, other.id]
    }

    func unsplit() { pair = nil }

    /// Add a session and bring it on screen.
    func add(_ session: TerminalSession) {
        sessions.append(session)
        activate(session)
        if let r = session.restorable { restore?.remember(r) }
    }

    /// Bring a session to the keyboard. In a split, one that isn't showing
    /// takes the place of the pane being looked at; the other pane stays.
    func activate(_ session: TerminalSession) {
        if var current = pair, !current.contains(session.id), let activeID, let slot = current.firstIndex(of: activeID) {
            current[slot] = session.id
            pair = current
        }
        activeID = session.id
    }

    /// Leave the terminal for the Connect / Keys tabs without closing anything.
    func goHome() { activeID = nil }

    func close(_ session: TerminalSession) {
        session.disconnect()
        restore?.forget(session.id)
        sessions.removeAll { $0.id == session.id }
        // Closing one side of a split leaves the other filling the space.
        if let pair, pair.contains(session.id) {
            let remaining = pair.first { $0 != session.id }
            self.pair = nil
            if activeID == session.id { activeID = remaining; return }
        }
        if activeID == session.id { activeID = sessions.last?.id }
    }
}
