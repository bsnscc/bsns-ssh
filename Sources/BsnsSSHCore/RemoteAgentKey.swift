import Foundation

/// A key that lives on another of the user's devices. To the agent it is a key
/// like any other; signing sends the request across the device link and waits
/// for the other device — and its owner — to answer.
///
/// The transport is a closure so this file knows nothing about networks: the
/// platform supplies "send this request to that device and give me its reply".
public struct RemoteAgentKey: KeyBackend {
    public let id: KeyID
    public let algorithm: KeyAlgorithm
    public let publicKey: SSHPublicKey
    public var canExport: Bool { false }
    /// The other device asks its owner before every signature.
    public var requiresUserPresence: Bool { true }

    private let transport: @Sendable (LinkRequest) async throws -> Data

    public init(publicKey: SSHPublicKey, transport: @escaping @Sendable (LinkRequest) async throws -> Data) {
        self.id = KeyID(SSHKeyFormat.fingerprint(ofPublicKeyBlob: publicKey.blob))
        self.algorithm = publicKey.algorithm
        self.publicKey = publicKey
        self.transport = transport
    }

    public func sign(_ data: Data, context: SignContext) async throws -> SSHSignature {
        // The same request any SSH client would send an agent; RSA keys choose
        // their hash through the flags (RFC 8332).
        let flags: UInt32
        switch context.rsaAlgorithm {
        case .sha512: flags = 0x04
        case .sha256: flags = 0x02
        case .sha1: flags = 0
        }
        let payload = SSHEncoder.build {
            $0.writeByte(SSHAgentMessageType.signRequest.rawValue)
            $0.writeString(publicKey.blob)
            $0.writeString(data)
            $0.writeUInt32(flags)
        }
        let reply: Data
        do {
            reply = try await transport(LinkRequest(agentPayload: payload, requester: context.requester,
                                                    host: context.host, user: context.user))
        } catch {
            throw KeyBackendError.signingFailed("couldn't reach the device holding this key")
        }
        var decoder = SSHDecoder(reply)
        guard (try? decoder.readByte()) == SSHAgentMessageType.signResponse.rawValue,
              let signature = try? decoder.readString() else {
            // The agent protocol has one failure reply for "declined" and "couldn't".
            throw KeyBackendError.userCancelled
        }
        return SSHSignature(blob: signature)
    }

    /// The identities in a remote agent's answer to "list your keys".
    public static func identities(inAnswer answer: Data) -> [SSHPublicKey] {
        var decoder = SSHDecoder(answer)
        guard (try? decoder.readByte()) == SSHAgentMessageType.identitiesAnswer.rawValue,
              let count = try? decoder.readUInt32(), count <= 256 else { return [] }
        var keys: [SSHPublicKey] = []
        for _ in 0..<count {
            guard let blob = try? decoder.readString(), let comment = try? decoder.readStringUTF8() else { break }
            var blobDecoder = SSHDecoder(blob)
            guard let name = try? blobDecoder.readStringUTF8(), let algorithm = KeyAlgorithm(rawValue: name) else { continue }
            keys.append(SSHPublicKey(blob: blob, algorithm: algorithm, comment: comment))
        }
        return keys
    }
}
