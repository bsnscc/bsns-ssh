import Foundation
import Dispatch
import Darwin
import CSSH
import BsnsSSHCore

// The iOS transport: an interactive SSH shell whose public-key auth is
// delegated to the Agent (same validated sign-callback bridge proven on
// macOS), now driving a live PTY. Built on libssh2 via the CSSH xcframework
// (libssh2 1.11.0 + OpenSSL). The private key never leaves the agent/backend.

private let LIBSSH2_ERROR_EAGAIN: Int = -37
private let BLOCK_INBOUND: Int32 = 0x0001
private let BLOCK_OUTBOUND: Int32 = 0x0002

public enum SSHShellError: Error {
    case libssh2Init, connectFailed, sessionInit, handshakeFailed
    case noHostKey, hostKeyMismatch(String, String)
    case noIdentities, authFailed(String)
    case channelOpenFailed, ptyFailed, shellFailed
}

/// Bridges libssh2's synchronous sign-callback to the async Agent: blocks the
/// shell thread on a semaphore while the actor signs, then returns the inner
/// signature body libssh2 expects.
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
        let agent = self.agent, blob = self.publicKeyBlob, context = self.signContext
        Task {
            box.value = try? await agent.sign(publicKeyBlob: blob, data: data, context: context)
            semaphore.signal()
        }
        semaphore.wait()
        guard let full = box.value?.blob else { return nil }
        var decoder = SSHDecoder(full)
        _ = try? decoder.readString()    // format
        return try? decoder.readString() // inner body
    }
}

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
    sig.pointee = buf.assumingMemoryBound(to: UInt8.self)
    sigLen.pointee = body.count
    return 0
}

/// A live interactive shell over SSH. Owns its session + channel on a dedicated
/// serial queue (libssh2 sessions are single-threaded); the UI feeds keystrokes
/// via `write` and receives output via `onOutput`.
public final class SSHShell: @unchecked Sendable {
    public var onOutput: (@Sendable (ArraySlice<UInt8>) -> Void)?
    public var onClosed: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "cc.bsns.ssh.shell")
    private let lock = NSLock()
    private var session: OpaquePointer?
    private var channel: OpaquePointer?
    private var fd: Int32 = -1
    private var running = false
    private var pendingWrite = Data()
    private var pendingResize: (cols: Int32, rows: Int32)?
    private var bridge: AgentSignBridge? // kept alive for the auth call

    public init() {}

    /// Connect, authenticate through `agent`, open a PTY + shell, and start the
    /// I/O loop. Returns once the shell is live (output then streams via
    /// `onOutput`). `knownHosts` mismatches are refused.
    public func connect(host: String, port: UInt16, user: String, agent: Agent,
                        cols: Int32 = 80, rows: Int32 = 24,
                        knownHosts: KnownHosts = KnownHosts()) async throws {
        let identities = await agent.identities()
        guard !identities.isEmpty else { throw SSHShellError.noIdentities }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.setup(host: host, port: port, user: user, agent: agent,
                                   identities: identities, cols: cols, rows: rows, knownHosts: knownHosts)
                    cont.resume()
                    self.runLoop()
                } catch {
                    self.teardown()
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func write(_ bytes: ArraySlice<UInt8>) {
        lock.lock(); pendingWrite.append(contentsOf: bytes); lock.unlock()
    }

    public func resize(cols: Int32, rows: Int32) {
        lock.lock(); pendingResize = (cols, rows); lock.unlock()
    }

    public func disconnect() {
        lock.lock(); running = false; lock.unlock()
    }

    // MARK: setup (blocking)

    private func setup(host: String, port: UInt16, user: String, agent: Agent,
                       identities: [SSHPublicKey], cols: Int32, rows: Int32, knownHosts: KnownHosts) throws {
        guard libssh2_init(0) == 0 else { throw SSHShellError.libssh2Init }
        guard let fd = Self.tcpConnect(host: host, port: port) else { throw SSHShellError.connectFailed }
        self.fd = fd
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else { throw SSHShellError.sessionInit }
        self.session = session
        libssh2_session_set_blocking(session, 1)
        guard libssh2_session_handshake(session, fd) == 0 else { throw SSHShellError.handshakeFailed }

        // Host key (TOFU): refuse a mismatch; proceed on trusted/unknown.
        let hostKey = try Self.presentedHostKey(session)
        if case let .mismatch(stored, presented) = knownHosts.verify(host: host, port: port, key: hostKey) {
            throw SSHShellError.hostKeyMismatch(stored, presented)
        }

        try authenticate(session, user: user, identities: identities, agent: agent, host: host)

        guard let channel = libssh2_channel_open_ex(session, "session", 7, 2 * 1024 * 1024, 32768, nil, 0) else {
            throw SSHShellError.channelOpenFailed
        }
        self.channel = channel

        let pty = "xterm-256color".withCString {
            libssh2_channel_request_pty_ex(channel, $0, UInt32(strlen($0)), nil, 0, cols, rows, 0, 0)
        }
        guard pty == 0 else { throw SSHShellError.ptyFailed }
        guard libssh2_channel_process_startup(channel, "shell", 5, nil, 0) == 0 else { throw SSHShellError.shellFailed }

        libssh2_session_set_blocking(session, 0) // non-blocking for the I/O loop
        lock.lock(); running = true; lock.unlock()
    }

    private func authenticate(_ session: OpaquePointer, user: String, identities: [SSHPublicKey], agent: Agent, host: String) throws {
        var lastError = "no identity accepted"
        for identity in identities {
            let bridge = AgentSignBridge(agent: agent, publicKeyBlob: identity.blob,
                                         signContext: SignContext(host: host, purpose: .sshUserAuth))
            self.bridge = bridge
            var abstract: UnsafeMutableRawPointer? = Unmanaged.passUnretained(bridge).toOpaque()
            let rc: Int32 = identity.blob.withUnsafeBytes { (pk: UnsafeRawBufferPointer) in
                withUnsafeMutablePointer(to: &abstract) { absP in
                    user.withCString { cuser in
                        libssh2_userauth_publickey(session, cuser,
                                                   pk.bindMemory(to: UInt8.self).baseAddress, pk.count,
                                                   agentSignCallback, absP)
                    }
                }
            }
            if rc == 0 { return }
            var message: UnsafeMutablePointer<CChar>?
            _ = libssh2_session_last_error(session, &message, nil, 0)
            lastError = message.map { String(cString: $0) } ?? "rc=\(rc)"
        }
        throw SSHShellError.authFailed(lastError)
    }

    // MARK: I/O loop (non-blocking)

    private func runLoop() {
        guard let session, let channel else { return }
        var buffer = [CChar](repeating: 0, count: 32768)
        while isRunning() {
            // Drain reads.
            while true {
                let n = libssh2_channel_read_ex(channel, 0, &buffer, buffer.count)
                if n > 0 {
                    onOutput?(ArraySlice(buffer[0 ..< Int(n)].map { UInt8(bitPattern: $0) }))
                } else if n == LIBSSH2_ERROR_EAGAIN {
                    break
                } else {
                    stop(); break
                }
            }
            if libssh2_channel_eof(channel) != 0 { stop(); break }

            // Drain pending writes.
            lock.lock(); let out = pendingWrite; pendingWrite.removeAll(keepingCapacity: true); lock.unlock()
            if !out.isEmpty {
                var sent = 0
                out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let base = raw.bindMemory(to: CChar.self).baseAddress!
                    while sent < out.count {
                        let w = libssh2_channel_write_ex(channel, 0, base + sent, out.count - sent)
                        if w == LIBSSH2_ERROR_EAGAIN { break }
                        if w < 0 { stop(); break }
                        sent += w
                    }
                }
                if sent < out.count { // requeue the unsent tail
                    lock.lock(); pendingWrite = out.suffix(out.count - sent) + pendingWrite; lock.unlock()
                }
            }

            // Apply a pending resize.
            lock.lock(); let resize = pendingResize; pendingResize = nil; lock.unlock()
            if let resize { libssh2_channel_request_pty_size_ex(channel, resize.cols, resize.rows, 0, 0) }

            waitSocket(session: session, timeoutMs: 30)
        }
        teardown()
        onClosed?()
    }

    private func waitSocket(session: OpaquePointer, timeoutMs: Int32) {
        var pfd = pollfd(fd: fd, events: 0, revents: 0)
        let dir = libssh2_session_block_directions(session)
        if dir & BLOCK_INBOUND != 0 { pfd.events |= Int16(POLLIN) }
        if dir & BLOCK_OUTBOUND != 0 { pfd.events |= Int16(POLLOUT) }
        if pfd.events == 0 { pfd.events = Int16(POLLIN) }
        poll(&pfd, 1, timeoutMs)
    }

    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }
    private func stop() { lock.lock(); running = false; lock.unlock() }

    private func teardown() {
        if let channel { libssh2_channel_free(channel); self.channel = nil }
        if let session { libssh2_session_free(session); self.session = nil }
        if fd >= 0 { close(fd); fd = -1 }
        libssh2_exit()
        bridge = nil
    }

    // MARK: helpers

    private static func presentedHostKey(_ session: OpaquePointer) throws -> HostKey {
        var length = 0
        var type: Int32 = 0
        guard let pointer = libssh2_session_hostkey(session, &length, &type) else { throw SSHShellError.noHostKey }
        let blob = Data(bytes: UnsafeRawPointer(pointer), count: length)
        let name: String
        switch type {
        case 1: name = "ssh-rsa"
        case 3: name = "ecdsa-sha2-nistp256"
        case 4: name = "ecdsa-sha2-nistp384"
        case 5: name = "ecdsa-sha2-nistp521"
        case 6: name = "ssh-ed25519"
        default: name = "unknown(\(type))"
        }
        return HostKey(keyType: name, blob: blob)
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
