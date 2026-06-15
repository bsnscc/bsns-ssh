import SwiftUI
import LocalAuthentication

/// Optional Face ID / Touch ID / passcode gate. When enabled, the app content is
/// covered until the device owner authenticates — including in the app switcher,
/// since we re-lock on backgrounding.
@MainActor
@Observable
final class AppLock {
    var locked: Bool = UserDefaults.standard.bool(forKey: SettingsKey.appLock)

    private var enabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.appLock) }

    func authenticate() {
        guard enabled else { locked = false; return }
        guard locked else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Passcode"
        var error: NSError?
        // If the device has no biometrics/passcode set, don't lock the user out.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            locked = false; return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock bsns.$_") { ok, _ in
            DispatchQueue.main.async { if ok { self.locked = false } }
        }
    }

    func lockIfEnabled() { if enabled { locked = true } }
}

/// Wraps the app content; shows a lock cover when `AppLock` is engaged and drives
/// authentication on launch / foreground, re-locking on background.
struct LockGate<Content: View>: View {
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var phase
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ZStack {
            content
            if lock.locked {
                LockScreen { lock.authenticate() }
                    .transition(.opacity)
            }
        }
        .onAppear { lock.authenticate() }
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .active: lock.authenticate()
            case .background: lock.lockIfEnabled()
            default: break
            }
        }
    }
}

private struct LockScreen: View {
    let unlock: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.051, green: 0.051, blue: 0.051).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("bsns")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                + Text(".")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0, green: 0.722, blue: 0.541))
                Button(action: unlock) {
                    Label("Unlock", systemImage: "lock.fill")
                        .font(.headline)
                        .padding(.horizontal, 22).padding(.vertical, 11)
                        .background(Color(red: 0, green: 0.722, blue: 0.541), in: Capsule())
                        .foregroundStyle(.black)
                }
            }
        }
    }
}
