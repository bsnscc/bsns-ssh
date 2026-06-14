import Foundation
import Dispatch
import Darwin
import CLibssh2
import BsnsSSHCore

// Real transport prototype (build-order step 3): an SSH session whose
// public-key authentication is delegated to the Agent, plus host-key (TOFU)
// verification and channel exec I/O. The private key never leaves the
// agent/backend. Written portably (only CLibssh2 + BsnsSSHCore); destined to
// be compiled against the libssh2 xcframework in the iOS app.

public enum SSHSessionError: Error, Sendable {
    case libssh2Init
    case connectFailed
    case sessionInit
    case handshakeFailed
    case noHostKey
    case hostKeyMismatch(stored: String, presented: String)
    case noIdentities
    case authFailed(String)
    case channelOpenFailed
    case execFailed(String)
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
        var decoder = SSHDecoder(full)
        _ = try? decoder.readString() // format
        return try? decoder.readString() // inner body
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

    /// Connect and authenticate by delegating signing to `agent`. Returns the
    /// presented host key and its TOFU verdict against `knownHosts`.
    @discardableResult
    public func connect(host: String, port: UInt16, user: String, agent: Agent, knownHosts: KnownHosts = KnownHosts()) async throws -> (hostKey: HostKey, verdict: HostVerification) {
        let result = try await perform(command: nil, host: host, port: port, user: user, agent: agent, knownHosts: knownHosts)
        return (result.hostKey, result.verdict)
    }

    /// Connect, authenticate through the agent, run `command`, and return its
    /// stdout — proving the channel/exec path on top of agent-delegated auth.
    public func runCommand(_ command: String, host: String, port: UInt16, user: String, agent: Agent, knownHosts: KnownHosts = KnownHosts()) async throws -> String {
        let result = try await perform(command: command, host: host, port: port, user: user, agent: agent, knownHosts: knownHosts)
        return result.output
    }

    private struct PerformResult: Sendable {
        let hostKey: HostKey
        let verdict: HostVerification
        let output: String
    }

    private func perform(command: String?, host: String, port: UInt16, user: String, agent: Agent, knownHosts: KnownHosts) async throws -> PerformResult {
        let identities = await agent.identities()
        guard !identities.isEmpty else { throw SSHSessionError.noIdentities }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PerformResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.run(command: command, host: host, port: port, user: user, identities: identities, agent: agent, knownHosts: knownHosts)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func run(command: String?, host: String, port: UInt16, user: String, identities: [SSHPublicKey], agent: Agent, knownHosts: KnownHosts) throws -> PerformResult {
        guard libssh2_init(0) == 0 else { throw SSHSessionError.libssh2Init }
        defer { libssh2_exit() }
        guard let fd = tcpConnect(host: host, port: port) else { throw SSHSessionError.connectFailed }
        defer { close(fd) }
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else { throw SSHSessionError.sessionInit }
        defer { libssh2_session_free(session) }
        libssh2_session_set_blocking(session, 1)
        guard libssh2_session_handshake(session, fd) == 0 else { throw SSHSessionError.handshakeFailed }

        // Host key (TOFU). The app surfaces .unknown / .mismatch to the user;
        // here we proceed on trusted/unknown and refuse a mismatch.
        let hostKey = try presentedHostKey(session)
        let verdict = knownHosts.verify(host: host, port: port, key: hostKey)
        if case let .mismatch(stored, presented) = verdict {
            throw SSHSessionError.hostKeyMismatch(stored: stored, presented: presented)
        }

        try authenticate(session, user: user, identities: identities, agent: agent, host: host)

        let output = try command.map { try exec($0, session: session) } ?? ""
        return PerformResult(hostKey: hostKey, verdict: verdict, output: output)
    }

    private static func presentedHostKey(_ session: OpaquePointer) throws -> HostKey {
        var length = 0
        var type: Int32 = 0
        guard let pointer = libssh2_session_hostkey(session, &length, &type) else {
            throw SSHSessionError.noHostKey
        }
        let blob = Data(bytes: UnsafeRawPointer(pointer), count: length)
        return HostKey(keyType: hostKeyTypeName(type), blob: blob)
    }

    private static func authenticate(_ session: OpaquePointer, user: String, identities: [SSHPublicKey], agent: Agent, host: String) throws {
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
            if rc == 0 { return }
            var message: UnsafeMutablePointer<CChar>?
            _ = libssh2_session_last_error(session, &message, nil, 0)
            lastError = message.map { String(cString: $0) } ?? "rc=\(rc)"
        }
        throw SSHSessionError.authFailed(lastError)
    }

    private static func exec(_ command: String, session: OpaquePointer) throws -> String {
        guard let channel = libssh2_channel_open_ex(session, "session", 7, 2 * 1024 * 1024, 32768, nil, 0) else {
            throw SSHSessionError.channelOpenFailed
        }
        defer { libssh2_channel_free(channel) }

        let startup = command.withCString { messagePtr in
            libssh2_channel_process_startup(channel, "exec", 4, messagePtr, UInt32(strlen(messagePtr)))
        }
        guard startup == 0 else { throw SSHSessionError.execFailed("process_startup rc=\(startup)") }

        var output = Data()
        let bufferSize = 32768
        var buffer = [CChar](repeating: 0, count: bufferSize)
        while true {
            let n = libssh2_channel_read_ex(channel, 0, &buffer, bufferSize)
            if n <= 0 { break } // 0 = EOF, <0 = error/EAGAIN (blocking mode -> done)
            output.append(contentsOf: buffer[0 ..< Int(n)].map { UInt8(bitPattern: $0) })
        }
        libssh2_channel_close(channel)
        return String(data: output, encoding: .utf8) ?? ""
    }

    private static func hostKeyTypeName(_ type: Int32) -> String {
        switch type {
        case 1: return "ssh-rsa"
        case 2: return "ssh-dss"
        case 3: return "ecdsa-sha2-nistp256"
        case 4: return "ecdsa-sha2-nistp384"
        case 5: return "ecdsa-sha2-nistp521"
        case 6: return "ssh-ed25519"
        default: return "unknown(\(type))"
        }
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
