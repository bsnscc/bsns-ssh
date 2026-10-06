import UserNotifications
import CloudKit
import BsnsSSHCore

/// Runs when a push arrives, before the notification is shown. The push only
/// says "something is waiting"; this fetches the sealed message from the
/// user's private iCloud database, opens it with the key for the computer that
/// sent it, and replaces the placeholder with the real question and one button
/// per answer. If any step fails, the placeholder is shown unchanged and the
/// app sorts it out when opened.
final class NotificationService: UNNotificationServiceExtension {
    private var deliver: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        deliver = contentHandler
        fallback = request.content
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        Task {
            if let box = await self.sealedMessage(for: request), let ask = AskNotification.fill(content, from: box), ask.isQuestion {
                await AskNotification.register(options: ask.options)
            }
            self.finish(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let fallback { finish(fallback) }
    }

    private func finish(_ content: UNNotificationContent) {
        let handler = deliver
        deliver = nil
        handler?(content)
    }

    private func sealedMessage(for request: UNNotificationRequest) async -> Data? {
        let userInfo = request.content.userInfo
        if let inline = userInfo[AskNotification.inlineBox] as? String { return Data(base64Encoded: inline) }
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let recordID = notification.recordID else { return nil }
        let database = CKContainer(identifier: "iCloud.cc.bsns.ssh").privateCloudDatabase
        // The record can trail its own push by a moment.
        for attempt in 0..<3 {
            if let record = try? await database.record(for: recordID), let box = record["box"] as? Data { return box }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        return nil
    }
}
