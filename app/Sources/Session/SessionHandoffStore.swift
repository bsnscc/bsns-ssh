import Foundation
import Observation
import BsnsSSHCore
#if canImport(UIKit)
import UIKit
#endif

/// Sessions moving between devices. This device keeps a small encrypted file of
/// its open sessions in the sync folder; the other devices' files become the
/// "on your other devices" list here. Opening one attaches the same tmux
/// session, so the work carries over rather than the connection.
///
/// Rides on config sync: same folder, same passphrase, and it does nothing
/// until both are set. The storage provider sees only ciphertext.
@MainActor
@Observable
final class SessionHandoffStore {
    private(set) var offers: [HandoffOffer] = []

    private static let enabledKey = "handoff.enabled"
    private static let deviceKey = "handoff.deviceID"

    /// On by default once sync is set up; turning it off removes this device's file.
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    /// Names this device's file. Random, and means nothing outside this app.
    let deviceID: String

    @ObservationIgnored private var published: [HandoffSession]?
    @ObservationIgnored private var publishedAt = Date.distantPast
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var openHere: [HandoffSession] = []
    @ObservationIgnored private var documents: [HandoffDocument] = []

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if let saved = defaults.string(forKey: Self.deviceKey), SessionHandoff.isValidDeviceID(saved) {
            deviceID = saved
        } else {
            deviceID = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
            defaults.set(deviceID, forKey: Self.deviceKey)
        }
    }

    static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    /// Record what is open here. Writes this device's file when the set changed,
    /// or once a day so a long-lived session doesn't age out of the others' lists.
    func publish(_ sessions: [RestorableSession], sync: SyncStore) {
        let mine = sessions.map {
            HandoffSession(id: $0.id, title: $0.title, host: $0.host, port: $0.port, user: $0.user,
                           useMosh: $0.useMosh, keyBlob: $0.keyBlob, tmuxSession: $0.tmuxSession)
        }
        openHere = mine
        offers = SessionHandoff.offers(from: documents, thisDevice: deviceID, openHere: mine)
        let name = SessionHandoff.fileName(deviceID: deviceID)
        guard enabled else {
            if published != nil { sync.remove(named: name) }
            published = nil
            return
        }
        guard sync.autoEnabled, let phrase = sync.loadPassphrase() else { return }
        if mine == published, Date().timeIntervalSince(publishedAt) < 24 * 3600 { return }
        published = mine
        publishedAt = Date()
        generation += 1
        let current = generation
        // Nothing open: leave no file behind rather than an empty one.
        if mine.isEmpty {
            sync.remove(named: name)
            return
        }
        let document = HandoffDocument(deviceID: deviceID, deviceName: Self.deviceName, updatedAt: Date(), sessions: mine)
        Task {
            // Key derivation is deliberately slow; keep it off the main thread.
            let sealed = await Task.detached { () -> Data? in
                guard let plain = try? SessionHandoff.encode(document) else { return nil }
                return try? ConfigCrypto.encrypt(plain, passphrase: phrase)
            }.value
            // A later change overtook this one while it was being sealed.
            guard let sealed, current == self.generation else { return }
            do { try sync.write(sealed, named: name) }
            catch { DiagLog.log("handoff", "publish failed: \(error.localizedDescription)") }
        }
    }

    /// Read the other devices' files. Ones that don't open with this device's
    /// passphrase, or that a newer version wrote, are skipped.
    func refresh(sync: SyncStore) async {
        guard enabled, sync.autoEnabled, let phrase = sync.loadPassphrase() else {
            documents = []
            offers = []
            return
        }
        var sealed: [Data] = []
        for name in sync.fileNames() {
            guard let device = SessionHandoff.deviceID(fromFileName: name), device != deviceID,
                  let data = try? sync.read(named: name) else { continue }
            sealed.append(data)
        }
        let opened = await Task.detached { () -> [HandoffDocument] in
            sealed.compactMap { data in
                guard let plain = try? ConfigCrypto.decrypt(data, passphrase: phrase) else { return nil }
                return try? SessionHandoff.decode(plain)
            }
        }.value
        documents = opened
        offers = SessionHandoff.offers(from: opened, thisDevice: deviceID, openHere: openHere)
    }

    /// One line under an offered session: where it is and how fresh.
    static func caption(for offer: HandoffOffer) -> String {
        let s = offer.session
        var parts = ["\(s.user)@\(s.host)\(s.port == 22 ? "" : ":\(s.port)")"]
        if let tmux = s.tmuxSession, !tmux.isEmpty { parts.append("tmux \(tmux)") } else { parts.append("new shell") }
        parts.append("\(offer.deviceName), \(offer.updatedAt.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: " · ")
    }
}
