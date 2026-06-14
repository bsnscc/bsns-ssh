import Foundation

/// SSH-agent protocol message numbers (draft-miller-ssh-agent).
public enum SSHAgentMessageType: UInt8, Sendable {
    case failure = 5
    case success = 6
    case requestIdentities = 11
    case identitiesAnswer = 12
    case signRequest = 13
    case signResponse = 14
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

    public init() {}

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
        return try await backend.sign(data, context: context)
    }

    /// Sign for the key identified by its public-key blob (as it appears in an
    /// identities answer / sign request).
    public func sign(publicKeyBlob: Data, data: Data, context: SignContext) async throws -> SSHSignature {
        guard let backend = order.lazy.compactMap({ self.backends[$0] }).first(where: { $0.publicKey.blob == publicKeyBlob }) else {
            throw AgentError.unknownKey
        }
        return try await backend.sign(data, context: context)
    }

    // MARK: SSH-agent protocol

    /// Process one SSH-agent request *payload* (without the outer `uint32`
    /// length frame) and return the response payload. This is the surface the
    /// network exposure wraps with a socket + framing.
    public func handleAgentMessage(_ payload: Data, context: SignContext) async -> Data {
        do {
            var decoder = SSHDecoder(payload)
            guard let type = SSHAgentMessageType(rawValue: try decoder.readByte()) else {
                return Self.failure()
            }
            switch type {
            case .requestIdentities:
                return identitiesAnswer()
            case .signRequest:
                let keyBlob = try decoder.readString()
                let data = try decoder.readString()
                _ = try decoder.readUInt32() // flags (rsa-sha2 selection) — handled later
                let signature = try await sign(publicKeyBlob: keyBlob, data: data, context: context)
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

    private func identitiesAnswer() -> Data {
        let keys = identities()
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
