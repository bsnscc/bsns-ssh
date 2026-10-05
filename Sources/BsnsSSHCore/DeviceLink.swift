import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The link between two of the user's own devices — one holding keys (a phone),
/// one wanting signatures (a computer) — over a network neither of them trusts.
///
/// Two protocols live here, both pure functions over bytes so they can be
/// tested without a network and ported without change:
///
/// **Pairing** (once). The devices have no shared secret and no authority to
/// vouch for them, so the user is the authority: each device derives a short
/// code from both devices' public keys and the user checks that the two
/// screens agree. For that check to mean anything, neither side may be able to
/// pick its key after seeing the other's — otherwise an attacker in the middle
/// could search for a key that makes the codes collide. So the initiator
/// *commits* to its key first, the responder answers with its own, and only
/// then does the initiator reveal. An attacker gets one guess at a six-digit
/// code, not a search.
///
/// **Sessions** (every connection after). Both devices hold each other's
/// long-term public key. Each contributes a fresh ephemeral key; the session
/// keys are derived from three Diffie-Hellman results that together require
/// *both* long-term private keys and *both* ephemerals. Only the paired devices
/// can derive them (mutual authentication), and a long-term key stolen later
/// does not open a recorded session (forward secrecy). This is the shape of
/// Noise's KK pattern, written out directly.
public enum DeviceLink {
    /// Bonjour service type the key-holding device advertises.
    public static let serviceType = "_bsns-key._tcp"
    public static let version: UInt8 = 1
    /// The port the key-holding device listens on when it is free. Discovery
    /// on a local network doesn't need it (the advertisement carries the port);
    /// a computer reaching the device by address — across a tailnet — does.
    public static let port: UInt16 = 47822

    public enum LinkError: Error, Equatable {
        case malformed, unsupportedVersion, commitmentMismatch, unknownPeer, weakKey, authenticationFailed
        case counterExhausted
    }

    static func sha256(_ parts: Data...) -> Data {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

/// A device's long-term link key (X25519). The private half stays in the
/// device's keychain; the public half is what pairing exchanges.
public struct LinkIdentity: Sendable {
    let key: Curve25519.KeyAgreement.PrivateKey

    public init() { key = Curve25519.KeyAgreement.PrivateKey() }

    public init(privateKeyData: Data) throws {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData) else {
            throw DeviceLink.LinkError.malformed
        }
        self.key = key
    }

    public var privateKeyData: Data { key.rawRepresentation }
    public var publicKey: Data { key.publicKey.rawRepresentation }

    /// A short stable name for this device on the network: derived from the
    /// public key, so it identifies the device without describing its owner.
    public var deviceID: String { LinkIdentity.deviceID(forPublicKey: publicKey) }

    public static func deviceID(forPublicKey publicKey: Data) -> String {
        DeviceLink.sha256(Data("bsns-link-id".utf8), publicKey).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// A device this one has been paired with.
public struct LinkPeer: Sendable, Codable, Equatable, Identifiable {
    public var publicKey: Data
    public var name: String
    public var id: String { LinkIdentity.deviceID(forPublicKey: publicKey) }

    public init(publicKey: Data, name: String) {
        self.publicKey = publicKey
        self.name = name
    }
}

// MARK: - Pairing

/// The result of a pairing exchange, before the user has confirmed it.
public struct PairingOutcome: Sendable, Equatable {
    public let peer: LinkPeer
    /// Six digits both devices show. Pairing is only valid if the user sees the
    /// same digits on both screens.
    public let code: String
}

enum PairingWire {
    static let helloTag: UInt8 = 0x50   // 'P'

    static func commitment(publicKey: Data, nonce: Data) -> Data {
        DeviceLink.sha256(Data("bsns-pair-commit-v1".utf8), publicKey, nonce)
    }

    /// Bound to everything either side contributed, names included, so a
    /// substituted name changes the code just as a substituted key does.
    static func code(initiatorKey: Data, initiatorNonce: Data, initiatorName: String,
                     responderKey: Data, responderNonce: Data, responderName: String) -> String {
        let material = SSHEncoder.build {
            $0.writeString("bsns-pair-code-v1")
            $0.writeString(initiatorKey); $0.writeString(initiatorNonce); $0.writeString(initiatorName)
            $0.writeString(responderKey); $0.writeString(responderNonce); $0.writeString(responderName)
        }
        let digest = DeviceLink.sha256(material)
        let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return String(format: "%06llu", value % 1_000_000)
    }

    static func cleanName(_ name: String) -> String {
        let printable = name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }
        return String(String(String.UnicodeScalarView(printable)).prefix(64))
    }
}

/// The side that starts pairing (the computer).
public struct PairingInitiator: Sendable {
    private let identity: LinkIdentity
    private let name: String
    private let nonce = DeviceLink.randomBytes(32)

    public init(identity: LinkIdentity, name: String) {
        self.identity = identity
        self.name = PairingWire.cleanName(name)
    }

    /// First message: a commitment to this device's key, not the key itself.
    public func hello() -> Data {
        SSHEncoder.build {
            $0.writeByte(PairingWire.helloTag)
            $0.writeByte(DeviceLink.version)
            $0.writeString(PairingWire.commitment(publicKey: identity.publicKey, nonce: nonce))
        }
    }

    /// Given the responder's answer: the message that reveals this device's key,
    /// and the pairing to put in front of the user.
    public func reveal(afterResponse response: Data) throws -> (reveal: Data, outcome: PairingOutcome) {
        var decoder = SSHDecoder(response)
        guard let peerKey = try? decoder.readString(), peerKey.count == 32,
              let peerNonce = try? decoder.readString(), peerNonce.count == 32,
              let rawName = try? decoder.readStringUTF8() else { throw DeviceLink.LinkError.malformed }
        let peerName = PairingWire.cleanName(rawName)
        let reveal = SSHEncoder.build {
            $0.writeString(identity.publicKey)
            $0.writeString(nonce)
            $0.writeString(name)
        }
        let code = PairingWire.code(initiatorKey: identity.publicKey, initiatorNonce: nonce, initiatorName: name,
                                    responderKey: peerKey, responderNonce: peerNonce, responderName: peerName)
        return (reveal, PairingOutcome(peer: LinkPeer(publicKey: peerKey, name: peerName), code: code))
    }
}

/// The side that answers pairing (the phone).
public struct PairingResponder: Sendable {
    private let identity: LinkIdentity
    private let name: String
    private let nonce = DeviceLink.randomBytes(32)
    private var commitment: Data?

    public init(identity: LinkIdentity, name: String) {
        self.identity = identity
        self.name = PairingWire.cleanName(name)
    }

    /// Answer the hello with this device's key. It is chosen and sent while the
    /// initiator's key is still hidden behind its commitment.
    public mutating func respond(toHello hello: Data) throws -> Data {
        var decoder = SSHDecoder(hello)
        guard (try? decoder.readByte()) == PairingWire.helloTag else { throw DeviceLink.LinkError.malformed }
        guard (try? decoder.readByte()) == DeviceLink.version else { throw DeviceLink.LinkError.unsupportedVersion }
        guard let commitment = try? decoder.readString(), commitment.count == 32 else { throw DeviceLink.LinkError.malformed }
        self.commitment = commitment
        return SSHEncoder.build {
            $0.writeString(identity.publicKey)
            $0.writeString(nonce)
            $0.writeString(name)
        }
    }

    /// Check the revealed key against the commitment made at the start.
    public func finish(reveal: Data) throws -> PairingOutcome {
        guard let commitment else { throw DeviceLink.LinkError.malformed }
        var decoder = SSHDecoder(reveal)
        guard let peerKey = try? decoder.readString(), peerKey.count == 32,
              let peerNonce = try? decoder.readString(), peerNonce.count == 32,
              let rawName = try? decoder.readStringUTF8() else { throw DeviceLink.LinkError.malformed }
        guard PairingWire.commitment(publicKey: peerKey, nonce: peerNonce) == commitment else {
            throw DeviceLink.LinkError.commitmentMismatch
        }
        let peerName = PairingWire.cleanName(rawName)
        let code = PairingWire.code(initiatorKey: peerKey, initiatorNonce: peerNonce, initiatorName: peerName,
                                    responderKey: identity.publicKey, responderNonce: nonce, responderName: name)
        return PairingOutcome(peer: LinkPeer(publicKey: peerKey, name: peerName), code: code)
    }
}

// MARK: - Sessions

/// An established, encrypted, mutually authenticated channel. Each direction
/// has its own key and its own message counter, so a message can't be replayed,
/// reordered, or reflected back at its sender.
public struct LinkSession: Sendable {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        guard sendCounter < UInt64.max else { throw DeviceLink.LinkError.counterExhausted }
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sendCounter))
        sendCounter += 1
        var message = Data(capacity: box.ciphertext.count + box.tag.count)
        message.append(box.ciphertext)
        message.append(box.tag)
        return message
    }

    public mutating func open(_ message: Data) throws -> Data {
        guard message.count >= 16, receiveCounter < UInt64.max else { throw DeviceLink.LinkError.authenticationFailed }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(receiveCounter),
                                               ciphertext: message.dropLast(16), tag: message.suffix(16))
            let plaintext = try ChaChaPoly.open(box, using: receiveKey)
            receiveCounter += 1
            return plaintext
        } catch {
            throw DeviceLink.LinkError.authenticationFailed
        }
    }
}

enum SessionWire {
    static let helloTag: UInt8 = 0x53   // 'S'

    static func agree(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKeyData: Data) throws -> Data {
        guard let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData),
              let secret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey) else {
            throw DeviceLink.LinkError.weakKey
        }
        let bytes = secret.withUnsafeBytes { Data($0) }
        // A low-order point makes the result all zeros whatever our key is;
        // such a "shared" secret would authenticate nobody.
        guard bytes.contains(where: { $0 != 0 }) else { throw DeviceLink.LinkError.weakKey }
        return bytes
    }

    /// Both directions' keys, from the three agreements and the full transcript.
    static func keys(ee: Data, initiatorStaticResponderEphemeral: Data, initiatorEphemeralResponderStatic: Data,
                     initiatorStatic: Data, responderStatic: Data,
                     initiatorEphemeral: Data, responderEphemeral: Data) -> (initiatorToResponder: SymmetricKey, responderToInitiator: SymmetricKey) {
        let material = SymmetricKey(data: ee + initiatorStaticResponderEphemeral + initiatorEphemeralResponderStatic)
        let info = initiatorStatic + responderStatic + initiatorEphemeral + responderEphemeral
        let output = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: Data("bsns-link-session-v1".utf8),
                                           info: info, outputByteCount: 64)
        let bytes = output.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: bytes.prefix(32)), SymmetricKey(data: bytes.suffix(32)))
    }
}

/// Opens a session to a paired device.
public struct SessionInitiator: Sendable {
    private let identity: LinkIdentity
    private let peerPublicKey: Data
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()

    public init(identity: LinkIdentity, peer: LinkPeer) {
        self.identity = identity
        self.peerPublicKey = peer.publicKey
    }

    public func hello() -> Data {
        SSHEncoder.build {
            $0.writeByte(SessionWire.helloTag)
            $0.writeByte(DeviceLink.version)
            $0.writeString(identity.publicKey)
            $0.writeString(ephemeral.publicKey.rawRepresentation)
        }
    }

    public func finish(response: Data) throws -> LinkSession {
        var decoder = SSHDecoder(response)
        guard let peerEphemeral = try? decoder.readString(), peerEphemeral.count == 32 else {
            throw DeviceLink.LinkError.malformed
        }
        let keys = SessionWire.keys(
            ee: try SessionWire.agree(ephemeral, peerEphemeral),
            initiatorStaticResponderEphemeral: try SessionWire.agree(identity.key, peerEphemeral),
            initiatorEphemeralResponderStatic: try SessionWire.agree(ephemeral, peerPublicKey),
            initiatorStatic: identity.publicKey, responderStatic: peerPublicKey,
            initiatorEphemeral: ephemeral.publicKey.rawRepresentation, responderEphemeral: peerEphemeral)
        return LinkSession(sendKey: keys.initiatorToResponder, receiveKey: keys.responderToInitiator)
    }
}

/// Accepts a session from a paired device.
public enum SessionResponder {
    /// Returns the response to send and the session — which proves nothing about
    /// the caller until the first message from it opens: only the holder of the
    /// claimed long-term key can produce one that does.
    public static func accept(hello: Data, identity: LinkIdentity,
                              isPaired: (Data) -> Bool) throws -> (response: Data, session: LinkSession, peerPublicKey: Data) {
        var decoder = SSHDecoder(hello)
        guard (try? decoder.readByte()) == SessionWire.helloTag else { throw DeviceLink.LinkError.malformed }
        guard (try? decoder.readByte()) == DeviceLink.version else { throw DeviceLink.LinkError.unsupportedVersion }
        guard let peerStatic = try? decoder.readString(), peerStatic.count == 32,
              let peerEphemeral = try? decoder.readString(), peerEphemeral.count == 32 else {
            throw DeviceLink.LinkError.malformed
        }
        guard isPaired(peerStatic) else { throw DeviceLink.LinkError.unknownPeer }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let keys = SessionWire.keys(
            ee: try SessionWire.agree(ephemeral, peerEphemeral),
            initiatorStaticResponderEphemeral: try SessionWire.agree(ephemeral, peerStatic),
            initiatorEphemeralResponderStatic: try SessionWire.agree(identity.key, peerEphemeral),
            initiatorStatic: peerStatic, responderStatic: identity.publicKey,
            initiatorEphemeral: peerEphemeral, responderEphemeral: ephemeral.publicKey.rawRepresentation)
        let response = SSHEncoder.build { $0.writeString(ephemeral.publicKey.rawRepresentation) }
        return (response, LinkSession(sendKey: keys.responderToInitiator, receiveKey: keys.initiatorToResponder), peerStatic)
    }
}

// MARK: - What travels inside a session

/// A request from the computer to the key-holding device: an SSH agent message
/// (list identities, or sign), with who is asking and why — so the phone can
/// put a meaningful question in front of its owner.
public struct LinkRequest: Sendable, Equatable {
    public var agentPayload: Data
    public var requester: String?
    public var host: String?
    public var user: String?

    public init(agentPayload: Data, requester: String? = nil, host: String? = nil, user: String? = nil) {
        self.agentPayload = agentPayload
        self.requester = requester
        self.host = host
        self.user = user
    }

    public func encoded() -> Data {
        SSHEncoder.build {
            $0.writeString(agentPayload)
            $0.writeString(requester ?? "")
            $0.writeString(host ?? "")
            $0.writeString(user ?? "")
        }
    }

    public init(decoding data: Data) throws {
        var decoder = SSHDecoder(data)
        guard let payload = try? decoder.readString(),
              let requester = try? decoder.readStringUTF8(),
              let host = try? decoder.readStringUTF8(),
              let user = try? decoder.readStringUTF8() else { throw DeviceLink.LinkError.malformed }
        func text(_ s: String) -> String? {
            let clean = PairingWire.cleanName(s)
            return clean.isEmpty ? nil : clean
        }
        self.init(agentPayload: payload, requester: text(requester), host: text(host), user: text(user))
    }
}
