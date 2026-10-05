#if os(iOS)
import SwiftUI
import UIKit
import UserNotifications
import Observation
import BsnsSSHCore

/// Questions and notices from the user's paired computers, on the phone. They
/// arrive through the user's private iCloud database (see `CloudRelay`): a
/// push says something is waiting, the app opens the sealed record, and the
/// answer chosen here is sealed and sent back to the computer that asked.
@MainActor
@Observable
final class PhoneInbox {
    static let shared = PhoneInbox()
    static let enabledKey = "inbox.enabled"

    struct Item: Identifiable {
        let ask: Ask
        let from: LinkPeer
        var id: UUID { ask.id }
    }

    private(set) var items: [Item] = []
    private(set) var problem: String?
    @ObservationIgnored private var refreshing = false

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// Turn receiving on or off: notification permission, the push
    /// registration, and the iCloud subscription that triggers it.
    func setEnabled(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        problem = nil
        guard on else {
            await CloudRelay.shared.unsubscribe()
            items = []
            return
        }
        guard await CloudRelay.shared.isAvailable() else {
            problem = "This phone isn't signed in to iCloud, which is what delivers these."
            return
        }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if !granted { problem = "Notifications are off for this app, so nothing will announce itself. They still appear here." }
        UIApplication.shared.registerForRemoteNotifications()
        do { try await CloudRelay.shared.subscribe() }
        catch { problem = "Couldn't set up delivery: \(error.localizedDescription)" }
        await refresh()
    }

    /// At launch: keep the push registration current.
    func resume() {
        guard enabled else { return }
        UIApplication.shared.registerForRemoteNotifications()
        Task { await refresh() }
    }

    /// Read what is waiting. A push can arrive a moment before the record is
    /// findable, so an empty result is checked once more.
    func refresh(expectingNew: Bool = false) async {
        guard enabled, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        var found = await CloudRelay.shared.fetchAsks()
        if expectingNew, found.count <= items.count {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            found = await CloudRelay.shared.fetchAsks()
        }
        items = found.map { Item(ask: $0.ask, from: $0.from) }
        try? await UNUserNotificationCenter.current().setBadgeCount(items.filter { $0.ask.isQuestion }.count)
    }

    func answer(_ item: Item, choice: String) async {
        do {
            try await CloudRelay.shared.answer(item.ask, choice: choice, to: item.from)
            items.removeAll { $0.id == item.id }
            try? await UNUserNotificationCenter.current().setBadgeCount(items.filter { $0.ask.isQuestion }.count)
        } catch {
            problem = "Couldn't send that answer: \(error.localizedDescription)"
        }
    }

    func dismiss(_ item: Item) async {
        await CloudRelay.shared.dismiss(item.ask)
        items.removeAll { $0.id == item.id }
    }
}

/// Receives the push that says something arrived.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await PhoneInbox.shared.refresh(expectingNew: true)
        return .newData
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DiagLog.log("inbox", "push registration failed: \(error.localizedDescription)")
    }
}

/// What is waiting for an answer, at the top of the connect screen.
struct PhoneInboxSection: View {
    @State private var inbox = PhoneInbox.shared

    var body: some View {
        if inbox.enabled, !inbox.items.isEmpty {
            Section {
                ForEach(inbox.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: item.ask.isQuestion ? "questionmark.bubble" : "bell").foregroundStyle(Brand.accent)
                            Text(item.ask.source.map { "\($0) · \(item.ask.machine)" } ?? item.ask.machine)
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text(item.ask.created.formatted(.relative(presentation: .named)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.ask.text)
                        if item.ask.isQuestion {
                            HStack {
                                ForEach(item.ask.options, id: \.self) { option in
                                    Button(option) { Task { await inbox.answer(item, choice: option) } }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        Button("Dismiss", role: .destructive) { Task { await inbox.dismiss(item) } }
                    }
                }
            } header: {
                Text("Waiting for You")
            } footer: {
                if let problem = inbox.problem { Text(problem).foregroundStyle(.red) }
            }
        }
    }
}

/// The switch, with what it means, for the settings screen.
struct PhoneInboxSettings: View {
    @State private var inbox = PhoneInbox.shared
    @State private var on = PhoneInbox.shared.enabled
    @State private var working = false

    var body: some View {
        Section {
            Toggle("Get questions and notices from paired computers", isOn: $on)
                .disabled(working)
                .onChange(of: on) { _, value in
                    working = true
                    Task {
                        await inbox.setEnabled(value)
                        working = false
                    }
                }
            if let problem = inbox.problem { Text(problem).font(.callout).foregroundStyle(.orange) }
        } header: {
            Text("Inbox")
        } footer: {
            Text("A script on a paired computer can ask you something (\"Deploy to prod?\") or tell you something (\"Build finished\"). It reaches this phone — and your Watch — through your own private iCloud database, sealed with the keys the two devices exchanged when you paired them: Apple delivers it without being able to read it. Your answer goes back the same way and can only be one of the choices offered. The notification itself says only that something is waiting; open the app to read and answer it.")
        }
    }
}
#endif
