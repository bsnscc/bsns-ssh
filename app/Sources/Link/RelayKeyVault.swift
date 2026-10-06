import Foundation
import Security
import UserNotifications
import BsnsSSHCore

/// The message keys the notification extension needs, and nothing more.
///
/// The extension has to open a sealed question before it is shown, so it needs
/// the key for messages from each paired computer. It gets exactly that — one
/// derived key per computer — in a keychain group shared between the app and
/// the extension. The pairing identity, and every SSH key, stay in the app's
/// own keychain where the extension cannot reach them.
enum RelayKeyVault {
    struct Entry: Codable, Equatable {
        var peerID: String
        var peerName: String
        var localID: String
        var key: Data
    }

    private static let service = "cc.bsns.ssh.relay"
    private static let account = "channels"

    /// `<team prefix>cc.bsns.ssh.relay`. The prefix comes from the build, so a
    /// copy of the app signed by someone else uses their own group.
    static var accessGroup: String {
        (Bundle.main.object(forInfoDictionaryKey: "BsnsKeychainPrefix") as? String ?? "") + "cc.bsns.ssh.relay"
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: accessGroup,
         kSecUseDataProtectionKeychain as String: true]
    }

    /// Replace the stored keys. An empty list removes the item.
    @discardableResult
    static func store(_ entries: [Entry]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
        guard !entries.isEmpty, let data = try? JSONEncoder().encode(entries) else { return errSecSuccess }
        var add = query
        add[kSecValueData as String] = data
        // Readable while the phone is locked (a notification arrives then),
        // but never before its first unlock, and never restored to another device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> [Entry] {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}

/// What a decrypted notification carries, so the app knows what an answer
/// button refers to.
enum AskNotification {
    static let askID = "bsns-ask"
    static let peerID = "bsns-peer"
    static let options = "bsns-options"
    /// A sealed message supplied directly in the payload (used when testing;
    /// a real push names a record to fetch instead).
    static let inlineBox = "bsns-box64"

    /// One notification category per distinct set of answers, so each button
    /// carries its own wording.
    static func category(for options: [String]) -> String { "ask:" + options.joined(separator: "\u{1f}") }

    /// Open a sealed message with whichever shared key fits, and write what it
    /// says into the notification: who is asking, the question, and what the
    /// app needs to send an answer back. Returns the question, or nil if the
    /// message isn't from a paired computer, was altered, or has expired — in
    /// which case the notification is left as it was.
    @discardableResult
    static func fill(_ content: UNMutableNotificationContent, from box: Data, now: Date = Date()) -> Ask? {
        for entry in RelayKeyVault.load() {
            guard let channel = try? RelayChannel(keyData: entry.key, localID: entry.localID, peerID: entry.peerID),
                  let ask: Ask = try? channel.open(box, as: .ask), ask.expires > now else { continue }
            content.title = ask.source.map { "\($0) on \(ask.machine)" } ?? ask.machine
            content.body = ask.text
            content.userInfo[askID] = ask.id.uuidString
            content.userInfo[peerID] = entry.peerID
            content.userInfo[options] = ask.options
            if ask.isQuestion { content.categoryIdentifier = category(for: ask.options) }
            return ask
        }
        return nil
    }

    /// Buttons need a category that says what they are called. Answers differ
    /// from question to question, so the category for this set is added to the
    /// ones already registered. Answering needs the device unlocked: a locked
    /// phone on a table must not be able to approve a deploy.
    static func register(options: [String]) async {
        let center = UNUserNotificationCenter.current()
        let identifier = category(for: options)
        var categories = await center.notificationCategories()
        guard !categories.contains(where: { $0.identifier == identifier }) else { return }
        let actions = options.map { UNNotificationAction(identifier: $0, title: $0, options: [.authenticationRequired]) }
        categories.insert(UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: []))
        center.setNotificationCategories(categories)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}
