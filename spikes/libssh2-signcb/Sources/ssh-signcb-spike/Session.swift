import Foundation
import Dispatch
import Darwin
import CLibssh2
import BsnsSSHCore

// Real transport prototype (build-order step 3): an SSH session whose
// public-key authentication is delegated to the Agent. The private key never
// leaves the agent/backend — the architecture's whole point, now over a live
// connection. Written portably (only CLibssh2 + BsnsSSHCore); destined to be
// compiled against the libssh2 xcframework in the iOS app.

public enum SSHSessionError: Error, Sendable {
    case libssh2Init
    case connectFailed
    case sessionInit
    case handshakeFailed
    case noIdentities
    case authFailed(String)
}

/// Bridges libssh2's synchronous sign-callback to the async Agent. `signSync`
/// blocks the (dedicated background) libssh2 thread until the agent returns the
/// signature, then hands libssh2 the *inner* signature body it expects.
final class AgentSignBridge: @unchecked Sendable {
    let agent: Agent
    let publicKeyBlob: Data
    let signContext: SignContext

    init(agent: Agent, publicKeyBlob: Data, signContext: SignContext) {
        self.agent = agent
        self.publicKeyBlob = publicKeyBlob
        self.signContext = signContext
    }

    func signSync(_ data: Data) -> Data? {
        final class Box: @unchecked Sendable { var value: SSHSignature? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let agent = self.agent
        let blob = self.publicKeyBlob
        let context = self.signContext
        Task {
            box.value = try? await agent.sign(publicKeyBlob: blob, data: data, context: context)
            semaphore.signal()
        }
        semaphore.wait() // safe: this runs on a dispatch thread, not the cooperative pool

        guard let full = box.value?.blob else { return nil }
        // Unwrap the full SSH signature blob (string(format) || string(body))
        // to the inner body; libssh2 re-frames it with the algorithm name.
        var decoder = SSHDecoder(full)
        _ = try? decoder.readString() // format
        return try? decoder.readString() // body
    }
}

// C sign-callback. Reaches the AgentSignBridge via `abstract`.
private let agentSignCallback: @convention(c) (
    OpaquePointer?,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    UnsafeMutablePointer<Int>?,
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32 = { _, sig, sigLen, data, dataLen, abstract in
    guard let sig, let sigLen, let data, let ctx = abstract?.pointee else { return -1 }
    let bridge = Unmanaged<AgentSignBridge>.fromOpaque(ctx).takeUnretainedValue()
    let input = Data(UnsafeBufferPointer(start: data, count: dataLen))
    guard let body = bridge.signSync(input), let buf = malloc(body.count) else { return -1 }
    body.copyBytes(to: buf.assumingMemoryBound(to: UInt8.self), count: body.count)
    sig.pointee = buf.assumingMemoryBound(to: UInt8.self) // libssh2 frees this
    sigLen.pointee = body.count
    return 0
}

public struct SSHSession: Sendable {
    public init() {}

    /// Connect and authenticate by delegating signing to `agent`. Tries each
    /// agent identity in turn (as an SSH agent does). Runs libssh2 on a
    /// dedicated background thread so the async→sync sign bridge never blocks
    /// the Swift concurrency cooperative pool.
    public func connect(host: String, port: UInt16, user: String, agent: Agent) async throws {
        let identities = await agent.identities()
        guard !identities.isEmpty else { throw SSHSessionError.noIdentities }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.run(host: host, port: port, user: user, identities: identities, agent: agent)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func run(host: String, port: UInt16, user: String, identities: [SSHPublicKey], agent: Agent) throws {
        guard libssh2_init(0) == 0 else { throw SSHSessionError.libssh2Init }
        defer { libssh2_exit() }
        guard let fd = tcpConnect(host: host, port: port) else { throw SSHSessionError.connectFailed }
        defer { close(fd) }
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else { throw SSHSessionError.sessionInit }
        defer { libssh2_session_free(session) }
        libssh2_session_set_blocking(session, 1)
        guard libssh2_session_handshake(session, fd) == 0 else { throw SSHSessionError.handshakeFailed }

        var lastError = "no identity accepted"
        for identity in identities {
            let bridge = AgentSignBridge(
                agent: agent,
                publicKeyBlob: identity.blob,
                signContext: SignContext(host: host, purpose: .sshUserAuth)
            )
            var abstract: UnsafeMutableRawPointer? = Unmanaged.passUnretained(bridge).toOpaque()
            let rc: Int32 = withExtendedLifetime(bridge) {
                identity.blob.withUnsafeBytes { (pk: UnsafeRawBufferPointer) in
                    withUnsafeMutablePointer(to: &abstract) { absP in
                        user.withCString { cuser in
                            libssh2_userauth_publickey(
                                session, cuser,
                                pk.bindMemory(to: UInt8.self).baseAddress, pk.count,
                                agentSignCallback, absP
                            )
                        }
                    }
                }
            }
            if rc == 0 { return } // authenticated
            var message: UnsafeMutablePointer<CChar>?
            _ = libssh2_session_last_error(session, &message, nil, 0)
            lastError = message.map { String(cString: $0) } ?? "rc=\(rc)"
        }
        throw SSHSessionError.authFailed(lastError)
    }

    private static func tcpConnect(host: String, port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { close(fd); return nil }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 { close(fd); return nil }
        return fd
    }
}
