import Foundation

/// SSH-agent protocol message numbers (draft-miller-ssh-agent).
public enum SSHAgentMessageType: UInt8, Sendable {
    case failure = 5
    case success = 6
    case requestIdentities = 11
    case identitiesAnswer = 12
    case signRequest = 13
    case signResponse = 14
    case `extension` = 27
}

/// One use of a key, for the audit trail. Records what was asked and how it
/// ended — never the data that was signed.
public struct AgentAuditEvent: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable { case signed, declined, failed, refused }
    public var date: Date
    public var keyFingerprint: String
    public var keyComment: String
    public var host: String?
    public var user: String?
    /// The outside program that asked; nil for the app's own connections.
    public var requester: String?
    public var outcome: Outcome
}

public enum AgentError: Error, Sendable {
    case unknownKey
}

/// The heart of the app. Holds the set of available keys and answers signing
/// requests; it does not care where a key lives. Every SSH connection
/// authenticates *through* the agent, and the same `handleAgentMessage` entry
/// point is what the network exposure (phone-as-hardware-key) will feed bytes
/// into — so the SSH-agent protocol is spoken from day one, even while it is
/// only called in-process.
///
/// An `actor` so the key set and signing are safe under the concurrent access
/// the network agent will bring.
public actor Agent {
    private var backends: [KeyID: any KeyBackend] = [:]
    private var order: [KeyID] = []
    private var auditor: (@Sendable (AgentAuditEvent) -> Void)?

    public init() {}

    /// Every signing attempt is reported here, whatever asked for it.
    public func setAuditor(_ auditor: (@Sendable (AgentAuditEvent) -> Void)?) {
        self.auditor = auditor
    }

    private func signAudited(_ backend: any KeyBackend, _ data: Data, _ context: SignContext) async throws -> SSHSignature {
        var event = AgentAuditEvent(date: Date(), keyFingerprint: backend.id.rawValue,
                                    keyComment: backend.publicKey.comment, host: context.host,
                                    user: context.user, requester: context.requester, outcome: .signed)
        do {
            let signature = try await backend.sign(data, context: context)
            auditor?(event)
            return signature
        } catch {
            if case KeyBackendError.userCancelled = error { event.outcome = .declined }
            else if case KeyBackendError.notPermitted = error { event.outcome = .refused }
            else { event.outcome = .failed }
            auditor?(event)
            throw error
        }
    }

    // MARK: Key set

    public func add(_ backend: any KeyBackend) {
        if backends[backend.id] == nil { order.append(backend.id) }
        backends[backend.id] = backend
    }

    public func remove(_ id: KeyID) {
        backends[id] = nil
        order.removeAll { $0 == id }
    }

    public func identities() -> [SSHPublicKey] {
        order.compactMap { backends[$0]?.publicKey }
    }

    // MARK: Signing

    public func sign(keyID: KeyID, data: Data, context: SignContext) async throws -> SSHSignature {
        guard let backend = backends[keyID] else { throw AgentError.unknownKey }
        return try await signAudited(backend, data, context)
    }

    /// Sign for the key identified by its public-key blob (as it appears in an
    /// identities answer / sign request).
    public func sign(publicKeyBlob: Data, data: Data, context: SignContext) async throws -> SSHSignature {
        guard let backend = order.lazy.compactMap({ self.backends[$0] }).first(where: { $0.publicKey.blob == publicKeyBlob }) else {
            throw AgentError.unknownKey
        }
        return try await signAudited(backend, data, context)
    }

    // MARK: SSH-agent protocol

    /// Process one SSH-agent request *payload* (without the outer `uint32`
    /// length frame) and return the response payload. This is the surface the
    /// network exposure wraps with a socket + framing.
    ///
    /// `exposing` limits which keys this caller may see and use — an outside
    /// program can be offered only the keys that ask the user every time.
    public func handleAgentMessage(_ payload: Data, context: SignContext,
                                   exposing isExposed: (@Sendable (any KeyBackend) -> Bool)? = nil) async -> Data {
        do {
            var decoder = SSHDecoder(payload)
            guard let type = SSHAgentMessageType(rawValue: try decoder.readByte()) else {
                return Self.failure()
            }
            switch type {
            case .requestIdentities:
                return identitiesAnswer(exposing: isExposed)
            case .signRequest:
                let keyBlob = try decoder.readString()
                let data = try decoder.readString()
                if let isExposed {
                    // A key that isn't offered can't be used by naming it either.
                    guard let backend = backends.values.first(where: { $0.publicKey.blob == keyBlob }),
                          isExposed(backend) else { return Self.failure() }
                }
                // Flags select the RSA signature hash (RFC 8332): bit 0x04 =
                // rsa-sha2-512, 0x02 = rsa-sha2-256, none = ssh-rsa (SHA-1).
                // Ignored by non-RSA backends.
                let flags = try decoder.readUInt32()
                let rsaAlg: RSASignatureAlgorithm = (flags & 0x04) != 0 ? .sha512
                    : (flags & 0x02) != 0 ? .sha256 : .sha1
                let ctx = SignContext(host: context.host, purpose: context.purpose, rsaAlgorithm: rsaAlg,
                                      requester: context.requester, user: context.user,
                                      hostProven: context.hostProven)
                let signature = try await sign(publicKeyBlob: keyBlob, data: data, context: ctx)
                return SSHEncoder.build {
                    $0.writeByte(SSHAgentMessageType.signResponse.rawValue)
                    $0.writeString(signature.blob)
                }
            default:
                return Self.failure()
            }
        } catch {
            return Self.failure()
        }
    }

    private func identitiesAnswer(exposing isExposed: (@Sendable (any KeyBackend) -> Bool)?) -> Data {
        let keys = order.compactMap { backends[$0] }
            .filter { isExposed?($0) ?? true }
            .map(\.publicKey)
        return SSHEncoder.build { encoder in
            encoder.writeByte(SSHAgentMessageType.identitiesAnswer.rawValue)
            encoder.writeUInt32(UInt32(keys.count))
            for key in keys {
                encoder.writeString(key.blob)
                encoder.writeString(key.comment)
            }
        }
    }

    private static func failure() -> Data {
        Data([SSHAgentMessageType.failure.rawValue])
    }
}
