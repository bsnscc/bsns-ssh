import Foundation
import CloudKit
import BsnsSSHCore

/// Carries asks and answers between the user's paired devices through their
/// own private iCloud database — the one path that reaches a phone whose app
/// isn't open, because Apple delivers a push when a record arrives.
///
/// What is stored is sealed with the two devices' pairing keys
/// (`RelayChannel`): iCloud holds ciphertext plus which device a record is for
/// and when it was written. It can deliver, delay or drop a message; it cannot
/// read one, alter one, or make one up.
@MainActor
final class CloudRelay {
    static let shared = CloudRelay()
    static let containerID = "iCloud.cc.bsns.ssh"
    static let recordType = "Relay"
    static let subscriptionID = "asks-for-this-device"

    private let database = CKContainer(identifier: CloudRelay.containerID).privateCloudDatabase
    private var links: LinkStore { LinkStore.shared }

    private func channel(with peer: LinkPeer) -> RelayChannel? {
        try? RelayChannel(identity: links.identity, peer: peer)
    }

    private func record(_ kind: RelayChannel.Kind, askID: UUID, to peer: LinkPeer, box: Data) -> CKRecord {
        let id = CKRecord.ID(recordName: RelayChannel.recordName(kind, askID: askID, to: peer.id))
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["to"] = peer.id as NSString
        record["kind"] = NSNumber(value: kind.rawValue)
        record["box"] = box as NSData
        return record
    }

    /// Whether the user is signed in to iCloud on this device.
    func isAvailable() async -> Bool {
        (try? await CKContainer(identifier: Self.containerID).accountStatus()) == .available
    }

    // MARK: the asking side (a computer)

    /// Send a question or notice to every paired device.
    func publish(_ ask: Ask) async {
        for device in links.paired {
            guard let channel = channel(with: device.peer), let box = try? channel.seal(ask, as: .ask) else { continue }
            do { _ = try await database.save(record(.ask, askID: ask.id, to: device.peer, box: box)) }
            catch { DiagLog.log("relay", "publish failed: \(error.localizedDescription)") }
        }
    }

    /// Take a question back (answered here, expired, or its asker went away).
    func retract(_ ask: Ask) async {
        for device in links.paired {
            _ = try? await database.deleteRecord(
                withID: CKRecord.ID(recordName: RelayChannel.recordName(.ask, askID: ask.id, to: device.peer.id)))
        }
    }

    /// Look for answers to these questions. Each is fetched by name — the name
    /// follows from the question's id — and only counts if it opens with the
    /// key of a paired device.
    func collectAnswers(for asks: [Ask]) async -> [AskAnswer] {
        let mine = links.identity.deviceID
        var found: [AskAnswer] = []
        for ask in asks {
            let id = CKRecord.ID(recordName: RelayChannel.recordName(.answer, askID: ask.id, to: mine))
            guard let record = try? await database.record(for: id), let box = record["box"] as? Data else { continue }
            for device in links.paired {
                if let answer: AskAnswer = try? channel(with: device.peer)?.open(box, as: .answer), answer.askID == ask.id {
                    found.append(answer)
                    break
                }
            }
            _ = try? await database.deleteRecord(withID: id)
        }
        return found
    }

    // MARK: the answering side (a phone)

    /// Ask iCloud to push when something arrives for this device. The visible
    /// text is fixed — the question itself is only readable once the app has
    /// opened the sealed record.
    func subscribe() async throws {
        let predicate = NSPredicate(format: "to == %@ AND kind == %d", links.identity.deviceID, Int(RelayChannel.Kind.ask.rawValue))
        let subscription = CKQuerySubscription(recordType: Self.recordType, predicate: predicate,
                                               subscriptionID: Self.subscriptionID, options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.alertBody = "Something on one of your machines needs you."
        info.soundName = "default"
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }

    func unsubscribe() async {
        _ = try? await database.deleteSubscription(withID: Self.subscriptionID)
    }

    /// What is waiting for this device, opened. Records that don't open with a
    /// paired computer's key, or have expired, are removed.
    func fetchAsks() async -> [(ask: Ask, from: LinkPeer)] {
        let predicate = NSPredicate(format: "to == %@ AND kind == %d", links.identity.deviceID, Int(RelayChannel.Kind.ask.rawValue))
        guard let (results, _) = try? await database.records(matching: CKQuery(recordType: Self.recordType, predicate: predicate),
                                                           resultsLimit: 50) else { return [] }
        var asks: [(Ask, LinkPeer)] = []
        for (id, result) in results {
            guard let record = try? result.get(), let box = record["box"] as? Data else { continue }
            var opened: (Ask, LinkPeer)?
            for device in links.paired {
                if let ask: Ask = try? channel(with: device.peer)?.open(box, as: .ask) { opened = (ask, device.peer); break }
            }
            if let opened, opened.0.expires > Date() {
                asks.append(opened)
            } else {
                _ = try? await database.deleteRecord(withID: id)
            }
        }
        return asks.sorted { $0.0.created > $1.0.created }
    }

    /// Send the user's choice back to the computer that asked, and clear the
    /// question from this device's queue.
    func answer(_ ask: Ask, choice: String, to peer: LinkPeer) async throws {
        guard ask.options.contains(choice), let channel = channel(with: peer) else { return }
        let box = try channel.seal(AskAnswer(askID: ask.id, choice: choice), as: .answer)
        _ = try await database.save(record(.answer, askID: ask.id, to: peer, box: box))
        await dismiss(ask)
    }

    /// Remove a notice (or a question the user doesn't want) from the queue.
    func dismiss(_ ask: Ask) async {
        _ = try? await database.deleteRecord(
            withID: CKRecord.ID(recordName: RelayChannel.recordName(.ask, askID: ask.id, to: links.identity.deviceID)))
    }
}
