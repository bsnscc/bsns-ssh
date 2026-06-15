import GameController
import Observation

/// Tracks whether a physical keyboard is attached. When one is, most of the
/// on-screen key bar is redundant (the keyboard has Ctrl, Tab, arrows, …) — only
/// Esc is genuinely missing on most iPad keyboards, so the bar collapses to it.
@MainActor
@Observable
final class HardwareKeyboardMonitor {
    var isConnected: Bool = GCKeyboard.coalesced != nil

    private var observers: [NSObjectProtocol] = []

    func start() {
        isConnected = GCKeyboard.coalesced != nil
        // queue: .main guarantees these run on the main thread, but the closure
        // type is Sendable so the compiler can't infer MainActor isolation —
        // assert it (same pattern as YubiKeyCoordinator's background handler).
        let connect = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isConnected = true }
            }
        let disconnect = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isConnected = GCKeyboard.coalesced != nil }
            }
        observers = [connect, disconnect]
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }
}
