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

    /// Add a session and bring it on screen.
    func add(_ session: TerminalSession) {
        sessions.append(session)
        activeID = session.id
        if let r = session.restorable { restore?.remember(r) }
    }

    func activate(_ session: TerminalSession) { activeID = session.id }

    /// Leave the terminal for the Connect / Keys tabs without closing anything.
    func goHome() { activeID = nil }

    func close(_ session: TerminalSession) {
        session.disconnect()
        restore?.forget(session.id)
        sessions.removeAll { $0.id == session.id }
        if activeID == session.id { activeID = sessions.last?.id }
    }
}
