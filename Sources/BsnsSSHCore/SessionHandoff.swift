import Foundation

/// An open session as another device needs to know it in order to pick it up:
/// where it is, how it connects, and which tmux session holds the work.
public struct HandoffSession: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var host: String
    public var port: UInt16
    public var user: String
    public var useMosh: Bool
    /// The public key the session signed in with. Another device may not hold it
    /// (a hardware key lives on one device) and then uses its own.
    public var keyBlob: Data?
    public var tmuxSession: String?

    public init(id: UUID, title: String, host: String, port: UInt16, user: String,
                useMosh: Bool, keyBlob: Data? = nil, tmuxSession: String? = nil) {
        self.id = id; self.title = title; self.host = host; self.port = port; self.user = user
        self.useMosh = useMosh; self.keyBlob = keyBlob; self.tmuxSession = tmuxSession
    }

    /// Two sessions are the same piece of work when they attach the same tmux
    /// session as the same user on the same server. Without tmux there is
    /// nothing shared to attach to, so no two sessions are the same work.
    func isSameWork(as other: HandoffSession) -> Bool {
        guard let tmux = tmuxSession, !tmux.isEmpty, tmux == other.tmuxSession else { return false }
        return host.lowercased() == other.host.lowercased() && port == other.port && user == other.user
    }
}

/// What one device publishes: the sessions it has open right now.
public struct HandoffDocument: Codable, Sendable, Equatable {
    public var version: Int
    public var deviceID: String
    public var deviceName: String
    public var updatedAt: Date
    public var sessions: [HandoffSession]

    public init(deviceID: String, deviceName: String, updatedAt: Date, sessions: [HandoffSession]) {
        self.version = SessionHandoff.version
        self.deviceID = deviceID; self.deviceName = deviceName
        self.updatedAt = updatedAt; self.sessions = sessions
    }
}

/// A session open on another device that could be opened here.
public struct HandoffOffer: Sendable, Equatable, Identifiable {
    public var session: HandoffSession
    public var deviceID: String
    public var deviceName: String
    public var updatedAt: Date
    public var id: String { "\(deviceID)/\(session.id.uuidString)" }
    /// True when opening it here lands in the same work (a tmux session), rather
    /// than a new shell on the same server.
    public var continuesWork: Bool { !(session.tmuxSession ?? "").isEmpty }
}

/// Moving a session between devices. Each device keeps one small file of its
/// open sessions beside the sync bundle — its own file, so two devices never
/// write the same one — sealed with the same passphrase. Nothing here changes
/// the bundle's format.
public enum SessionHandoff {
    public static let version = 1
    static let filePrefix = "bsns-ssh-sessions-"
    static let fileSuffix = ".json"
    /// A device that hasn't published for this long is no longer offered.
    public static let maxAge: TimeInterval = 30 * 24 * 3600

    public enum HandoffError: Error, Equatable { case unsupportedVersion(Int), badDeviceID }

    public static func fileName(deviceID: String) -> String { filePrefix + deviceID + fileSuffix }

    /// The device a file in the sync folder belongs to; nil if it isn't one of these files.
    public static func deviceID(fromFileName name: String) -> String? {
        guard name.hasPrefix(filePrefix), name.hasSuffix(fileSuffix) else { return nil }
        let id = String(name.dropFirst(filePrefix.count).dropLast(fileSuffix.count))
        return isValidDeviceID(id) ? id : nil
    }

    public static func isValidDeviceID(_ id: String) -> Bool {
        (4...64).contains(id.count) && id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    public static func encode(_ document: HandoffDocument) throws -> Data {
        guard isValidDeviceID(document.deviceID) else { throw HandoffError.badDeviceID }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> HandoffDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(HandoffDocument.self, from: data)
        guard document.version <= version else { throw HandoffError.unsupportedVersion(document.version) }
        guard isValidDeviceID(document.deviceID) else { throw HandoffError.badDeviceID }
        return document
    }

    /// What to offer on this device: other devices' sessions, newest first,
    /// leaving out work already open here and devices long out of use. Work
    /// that two other devices both have open is offered once.
    public static func offers(from documents: [HandoffDocument], thisDevice: String,
                              openHere: [HandoffSession], now: Date = Date()) -> [HandoffOffer] {
        var offers: [HandoffOffer] = []
        let recent = documents
            .filter { $0.deviceID != thisDevice && now.timeIntervalSince($0.updatedAt) <= maxAge }
            .sorted { $0.updatedAt > $1.updatedAt }
        for document in recent {
            for session in document.sessions {
                if openHere.contains(where: { $0.isSameWork(as: session) }) { continue }
                if offers.contains(where: { $0.session.isSameWork(as: session) }) { continue }
                offers.append(HandoffOffer(session: session, deviceID: document.deviceID,
                                           deviceName: document.deviceName, updatedAt: document.updatedAt))
            }
        }
        return offers
    }
}
