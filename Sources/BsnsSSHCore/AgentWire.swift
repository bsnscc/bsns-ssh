import Foundation

/// The parts of serving the SSH agent protocol to other programs that don't
/// depend on how the bytes arrive — a Unix socket today, a named pipe or a
/// paired device later. The transport reads bytes, feeds them here, and writes
/// back what comes out.

/// Splits a byte stream into agent messages (`uint32 length || payload`).
public struct AgentFrameReader: Sendable {
    /// Larger than any real request (a sign request carries a session hash, not
    /// a payload), small enough that a confused client can't make us buffer
    /// without bound.
    public static let maxFrame = 256 * 1024

    public enum FrameError: Error, Equatable { case tooLarge }

    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// The next complete payload, or nil if more bytes are needed.
    public mutating func next() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length <= Self.maxFrame else { throw FrameError.tooLarge }
        guard buffer.count >= 4 + length else { return nil }
        let payload = Data(buffer.dropFirst(4).prefix(length))
        buffer = Data(buffer.dropFirst(4 + length))
        return payload
    }

    public static func frame(_ payload: Data) -> Data {
        var out = Data()
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

/// What can be read out of agent messages without trusting them.
public enum AgentWire {
    static let sessionBindExtension = "session-bind@openssh.com"

    /// A `session-bind@openssh.com` extension: the client telling the agent
    /// which server (by host key) a session id belongs to, before it asks for a
    /// signature over that session. This is the only way an agent learns where
    /// a key is about to be used.
    public static func sessionBind(_ payload: Data) -> (hostKeyBlob: Data, sessionID: Data)? {
        var decoder = SSHDecoder(payload)
        guard (try? decoder.readByte()) == SSHAgentMessageType.extension.rawValue,
              (try? decoder.readStringUTF8()) == sessionBindExtension,
              let hostKey = try? decoder.readString(),
              let sessionID = try? decoder.readString(),
              !hostKey.isEmpty, !sessionID.isEmpty else { return nil }
        return (hostKey, sessionID)
    }

    /// The session id and login name inside the data an SSH client asks to have
    /// signed for public-key authentication (RFC 4252 §7):
    /// `string session-id, byte 50, string user, string service, string method,
    /// bool, string algorithm, string key`. Current OpenSSH uses the method
    /// `publickey-hostbound-v00@openssh.com` when the server supports it, which
    /// appends the server's host key — so the request itself says where the key
    /// is being used, with no separate announcement needed.
    /// Nil for anything else — a signature request that isn't a login.
    public static func userAuthRequest(signedData: Data) -> (sessionID: Data, user: String, hostKeyBlob: Data?)? {
        var decoder = SSHDecoder(signedData)
        guard let sessionID = try? decoder.readString(),
              (try? decoder.readByte()) == 50,
              let user = try? decoder.readStringUTF8(),
              (try? decoder.readStringUTF8()) != nil,
              let method = try? decoder.readStringUTF8() else { return nil }
        switch method {
        case "publickey":
            return (sessionID, user, nil)
        case "publickey-hostbound-v00@openssh.com":
            guard (try? decoder.readByte()) != nil,
                  (try? decoder.readString()) != nil,
                  (try? decoder.readString()) != nil,
                  let hostKey = try? decoder.readString(), !hostKey.isEmpty else { return (sessionID, user, nil) }
            return (sessionID, user, hostKey)
        default:
            return nil
        }
    }

    /// The key and the data of a sign request.
    static func signRequest(_ payload: Data) -> (keyBlob: Data, data: Data)? {
        var decoder = SSHDecoder(payload)
        guard (try? decoder.readByte()) == SSHAgentMessageType.signRequest.rawValue,
              let keyBlob = try? decoder.readString(),
              let data = try? decoder.readString() else { return nil }
        return (keyBlob, data)
    }
}

/// One outside program's connection to the agent. Holds what that program has
/// said so far (which server its session is with) and answers its requests
/// with the right context attached — so a prompt can say "ssh wants to sign in
/// to graham@build-box" rather than just asking for a fingerprint.
public actor AgentClientConnection {
    private let agent: Agent
    private let requester: String?
    private let isExposed: (@Sendable (any KeyBackend) -> Bool)?
    private let hostName: @Sendable (Data) -> String?
    /// Host key announced for each session id on this connection.
    private var boundHosts: [Data: Data] = [:]

    /// - Parameters:
    ///   - requester: the connecting program, for prompts and the audit trail.
    ///   - exposing: which keys this program may see and use (nil = all).
    ///   - hostName: a known name for a host key blob, if the app has one.
    public init(agent: Agent, requester: String?,
                exposing isExposed: (@Sendable (any KeyBackend) -> Bool)? = nil,
                hostName: @escaping @Sendable (Data) -> String? = { _ in nil }) {
        self.agent = agent
        self.requester = requester
        self.isExposed = isExposed
        self.hostName = hostName
    }

    public func respond(to payload: Data) async -> Data {
        if let bind = AgentWire.sessionBind(payload) {
            // Bounded: a connection is one ssh process, which binds one session
            // (a few, with connection sharing).
            if boundHosts.count < 16 { boundHosts[bind.sessionID] = bind.hostKeyBlob }
            return Data([SSHAgentMessageType.success.rawValue])
        }
        var host: String?
        var user: String?
        var proven = false
        if let request = AgentWire.signRequest(payload),
           let auth = AgentWire.userAuthRequest(signedData: request.data) {
            user = auth.user
            // A host key inside the data to be signed makes the signature
            // worthless anywhere but in a session with that server. A host key
            // only announced beforehand is the program's word for it.
            proven = auth.hostKeyBlob != nil
            if let hostKey = auth.hostKeyBlob ?? boundHosts[auth.sessionID] {
                // A name the user will recognise if there is one; otherwise the
                // host key's fingerprint, which at least identifies the server.
                host = hostName(hostKey) ?? SSHKeyFormat.fingerprint(ofPublicKeyBlob: hostKey)
            }
        }
        let context = SignContext(host: host, purpose: .remoteAgent, requester: requester, user: user,
                                  hostProven: proven)
        return await agent.handleAgentMessage(payload, context: context, exposing: isExposed)
    }
}
