import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Something on one of the user's machines that wants their attention: a
/// question with a fixed set of answers ("Deploy to prod?" — approve / roll
/// back), or with no options, a plain notice ("Build finished").
public struct Ask: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    /// What the user may answer. Empty for a notice.
    public var options: [String]
    /// The machine it came from, for display.
    public var machine: String
    /// Who asked — a program or workspace name, when known.
    public var source: String?
    public var created: Date
    /// After this the question is void: an answer arriving later is ignored.
    public var expires: Date

    public static let maxText = 600
    public static let maxOptions = 4
    public static let maxOptionLength = 40

    public init(id: UUID = UUID(), text: String, options: [String] = [], machine: String, source: String? = nil,
                created: Date = Date(), lifetime: TimeInterval = 3600) {
        self.id = id
        self.text = String(text.prefix(Self.maxText))
        self.options = options.prefix(Self.maxOptions).map { String($0.prefix(Self.maxOptionLength)) }
        self.machine = machine
        self.source = source
        // Whole seconds: these travel as text and must come back identical.
        self.created = Date(timeIntervalSince1970: created.timeIntervalSince1970.rounded(.down))
        self.expires = self.created.addingTimeInterval(lifetime.rounded())
    }

    public var isQuestion: Bool { !options.isEmpty }

    /// An answer counts only if it picks one of the options offered, for this
    /// question, before it expired. An answer is a choice — it never carries
    /// anything to run.
    public func accepts(_ answer: AskAnswer, now: Date = Date()) -> Bool {
        answer.askID == id && now <= expires && options.contains(answer.choice)
    }
}

public struct AskAnswer: Codable, Sendable, Equatable {
    public var askID: UUID
    public var choice: String
    public var answered: Date

    public init(askID: UUID, choice: String, answered: Date = Date()) {
        self.askID = askID; self.choice = choice
        self.answered = Date(timeIntervalSince1970: answered.timeIntervalSince1970.rounded(.down))
    }
}

/// Seals asks and answers between this device and one paired device, so they
/// can travel through storage that must not be able to read or forge them.
///
/// The key comes from the two devices' pairing keys (a static Diffie-Hellman
/// agreement), so nothing new has to be exchanged: any two paired devices can
/// already talk this way, and nobody else can. Each message says what kind it
/// is and which way it is going, and that is authenticated along with the
/// contents — an ask can't be replayed as an answer, or a message turned
/// around and sent back to its author.
public struct RelayChannel: Sendable {
    public enum Kind: UInt8, Sendable { case ask = 1, answer = 2, withdraw = 3 }
    public enum RelayError: Error, Equatable { case malformed, wrongKind, notForUs }

    static let version: UInt8 = 1
    private let key: SymmetricKey
    public let localID: String
    public let peerID: String

    public init(identity: LinkIdentity, peer: LinkPeer) throws {
        guard let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.publicKey),
              let shared = try? identity.key.sharedSecretFromKeyAgreement(with: theirs) else {
            throw DeviceLink.LinkError.malformed
        }
        // Both public keys, in a fixed order, so the two ends derive the same key.
        let ordered = [identity.publicKey, peer.publicKey].sorted { $0.lexicographicallyPrecedes($1) }
        key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("bsns-relay-v1".utf8),
                                             sharedInfo: ordered[0] + ordered[1], outputByteCount: 32)
        localID = identity.deviceID
        peerID = peer.id
    }

    /// The channel's key, for a helper that must open messages without being
    /// given the pairing identity itself (a notification extension): with this
    /// it can read and answer asks from one paired device, and nothing else.
    public var keyData: Data { key.withUnsafeBytes { Data($0) } }

    /// Rebuild a channel from a key exported with `keyData`.
    public init(keyData: Data, localID: String, peerID: String) throws {
        guard keyData.count == 32 else { throw DeviceLink.LinkError.malformed }
        key = SymmetricKey(data: keyData)
        self.localID = localID
        self.peerID = peerID
    }

    private func header(_ kind: Kind, from: String, to: String) -> Data {
        Data([Self.version, kind.rawValue]) + Data(from.utf8) + Data([0]) + Data(to.utf8)
    }

    /// `version || kind || nonce || ciphertext || tag`
    public func seal<T: Encodable>(_ value: T, as kind: Kind) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let box = try ChaChaPoly.seal(try encoder.encode(value), using: key,
                                      authenticating: header(kind, from: localID, to: peerID))
        return Data([Self.version, kind.rawValue]) + box.combined
    }

    /// Open a message the peer sealed for this device. Fails for anything else:
    /// another kind, another direction, another pair, or any alteration.
    public func open<T: Decodable>(_ message: Data, as kind: Kind, _ type: T.Type = T.self) throws -> T {
        guard message.count > 2 + 12 + 16, message.first == Self.version else { throw RelayError.malformed }
        guard message[message.startIndex + 1] == kind.rawValue else { throw RelayError.wrongKind }
        guard let box = try? ChaChaPoly.SealedBox(combined: Data(message.dropFirst(2))),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: header(kind, from: peerID, to: localID)) else {
            throw RelayError.notForUs
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let value = try? decoder.decode(T.self, from: plain) else { throw RelayError.malformed }
        return value
    }

    /// The name of the stored record for an ask or its answer. Derived from the
    /// ask's id, so the asking machine can fetch the answer directly.
    public static func recordName(_ kind: Kind, askID: UUID, to deviceID: String) -> String {
        "\(kind == .answer ? "answer" : kind == .ask ? "ask" : "withdraw")-\(askID.uuidString.lowercased())-\(deviceID)"
    }
}
