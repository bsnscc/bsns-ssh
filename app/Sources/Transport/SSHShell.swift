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
    case noHostKey, unknownHostKey(HostKey), hostKeyMismatch(String, String)
    case noIdentities, authFailed(String)
    case channelOpenFailed, ptyFailed, shellFailed, execFailed(String)
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
    /// Called once when the loop ends. The argument is the drop reason, or `nil`
    /// for a clean close (remote EOF or a user-initiated `disconnect`).
    public var onClosed: (@Sendable (String?) -> Void)?

    private let queue = DispatchQueue(label: "cc.bsns.ssh.shell")
    private let lock = NSLock()
    private var session: OpaquePointer?
    private var channel: OpaquePointer?
    private var fd: Int32 = -1
    private var running = false
    private var userClosed = false
    private var closeReason: String?
    private var pendingWrite = Data()
    private var pendingResize: (cols: Int32, rows: Int32)?
    private var bridge: AgentSignBridge? // kept alive for the auth call
    // Self-pipe so write/resize wake the poll loop immediately instead of
    // waiting out the poll timeout — keystrokes are sent with no added latency.
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1

    public init() {}

    /// Connect, authenticate through `agent`, open a PTY + shell, and start the
    /// I/O loop. Returns once the shell is live (output then streams via
    /// `onOutput`). `knownHosts` mismatches are refused.
    public func connect(host: String, port: UInt16, user: String, agent: Agent,
                        cols: Int32 = 80, rows: Int32 = 24,
                        knownHosts: KnownHosts = KnownHosts(),
                        password: String? = nil) async throws {
        let usingPassword = !(password ?? "").isEmpty
        let identities = await agent.identities()
        guard usingPassword || !identities.isEmpty else { throw SSHShellError.noIdentities }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.setup(host: host, port: port, user: user, agent: agent,
                                   identities: identities, cols: cols, rows: rows,
                                   knownHosts: knownHosts, password: password)
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
        wake()
    }

    public func resize(cols: Int32, rows: Int32) {
        lock.lock(); pendingResize = (cols, rows); lock.unlock()
        wake()
    }

    public func disconnect() {
        lock.lock(); running = false; userClosed = true; lock.unlock()
        wake()
    }

    private func wake() {
        if wakeWrite >= 0 { var byte: UInt8 = 1; _ = Darwin.write(wakeWrite, &byte, 1) }
    }

    // MARK: setup (blocking)

    private func setup(host: String, port: UInt16, user: String, agent: Agent,
                       identities: [SSHPublicKey], cols: Int32, rows: Int32, knownHosts: KnownHosts,
                       password: String?) throws {
        guard libssh2_init(0) == 0 else { throw SSHShellError.libssh2Init }
        guard let fd = Self.tcpConnect(host: host, port: port) else { throw SSHShellError.connectFailed }
        self.fd = fd
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else { throw SSHShellError.sessionInit }
        self.session = session
        libssh2_session_set_blocking(session, 1)
        guard libssh2_session_handshake(session, fd) == 0 else { throw SSHShellError.handshakeFailed }

        // Host key (TOFU): proceed only if trusted; surface unknown (prompt) and
        // mismatch (danger) to the caller, which decides whether to trust + retry.
        let hostKey = try Self.presentedHostKey(session)
        switch knownHosts.verify(host: host, port: port, key: hostKey) {
        case .trusted:
            break
        case .unknown:
            throw SSHShellError.unknownHostKey(hostKey)
        case let .mismatch(stored, presented):
            throw SSHShellError.hostKeyMismatch(stored, presented)
        }

        if let password, !password.isEmpty {
            try Self.passwordAuth(session, user: user, password: password)
        } else {
            try authenticate(session, user: user, identities: identities, agent: agent, host: host)
        }

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
        // Server-replied keepalives every 30s keep NAT/firewall mappings alive
        // and let us notice a dead peer instead of hanging on a silent socket.
        libssh2_keepalive_config(session, 1, 30)

        var fds: [Int32] = [-1, -1]
        if pipe(&fds) == 0 {
            wakeRead = fds[0]; wakeWrite = fds[1]
            _ = fcntl(wakeRead, F_SETFL, O_NONBLOCK)
            _ = fcntl(wakeWrite, F_SETFL, O_NONBLOCK)
        }
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

    static func passwordAuth(_ session: OpaquePointer, user: String, password: String) throws {
        let rc = user.withCString { cuser in
            password.withCString { cpass in
                libssh2_userauth_password_ex(session, cuser, UInt32(strlen(cuser)), cpass, UInt32(strlen(cpass)), nil)
            }
        }
        if rc != 0 {
            var message: UnsafeMutablePointer<CChar>?
            _ = libssh2_session_last_error(session, &message, nil, 0)
            throw SSHShellError.authFailed(message.map { String(cString: $0) } ?? "password rejected")
        }
    }

    /// ssh-copy-id: connect with a password and append the given public-key
    /// lines to the server's ~/.ssh/authorized_keys (deduped). The keys are
    /// base64-wrapped to keep them clear of shell quoting.
    public static func installPublicKeys(_ lines: [String], host: String, port: UInt16, user: String,
                                         password: String, knownHosts: KnownHosts = KnownHosts()) async throws {
        // Single-quote each line (escaping any embedded quote) so spaces and
        // base64 are shell-safe without relying on base64 -d (which differs on
        // macOS/BSD servers). Append each line only if not already present.
        let quoted = lines
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        let command = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && "
            + "chmod 600 ~/.ssh/authorized_keys && for line in \(quoted); do "
            + "grep -qxF -- \"$line\" ~/.ssh/authorized_keys || echo \"$line\" >> ~/.ssh/authorized_keys; done"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try runExec(host: host, port: port, user: user, password: password, command: command, knownHosts: knownHosts)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func runExec(host: String, port: UInt16, user: String, password: String,
                                command: String, knownHosts: KnownHosts) throws {
        guard libssh2_init(0) == 0 else { throw SSHShellError.libssh2Init }
        defer { libssh2_exit() }
        guard let fd = tcpConnect(host: host, port: port) else { throw SSHShellError.connectFailed }
        defer { close(fd) }
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else { throw SSHShellError.sessionInit }
        defer { libssh2_session_free(session) }
        libssh2_session_set_blocking(session, 1)
        guard libssh2_session_handshake(session, fd) == 0 else { throw SSHShellError.handshakeFailed }

        let hostKey = try presentedHostKey(session)
        switch knownHosts.verify(host: host, port: port, key: hostKey) {
        case .trusted: break
        case .unknown: throw SSHShellError.unknownHostKey(hostKey)
        case let .mismatch(stored, presented): throw SSHShellError.hostKeyMismatch(stored, presented)
        }

        try passwordAuth(session, user: user, password: password)

        guard let channel = libssh2_channel_open_ex(session, "session", 7, 2 * 1024 * 1024, 32768, nil, 0) else {
            throw SSHShellError.channelOpenFailed
        }
        defer { libssh2_channel_free(channel) }
        let startup = command.withCString {
            libssh2_channel_process_startup(channel, "exec", 4, $0, UInt32(strlen($0)))
        }
        guard startup == 0 else { throw SSHShellError.execFailed("process_startup rc=\(startup)") }

        var buffer = [CChar](repeating: 0, count: 4096)
        while libssh2_channel_read_ex(channel, 0, &buffer, buffer.count) > 0 {}
        libssh2_channel_close(channel)
        let exitStatus = libssh2_channel_get_exit_status(channel)
        if exitStatus != 0 { throw SSHShellError.execFailed("remote exit \(exitStatus)") }
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
                    fail(session, "connection lost"); break
                }
            }
            if !isRunning() { break }
            if libssh2_channel_eof(channel) != 0 { stop(); break } // clean remote close

            // Drain pending writes.
            lock.lock(); let out = pendingWrite; pendingWrite.removeAll(keepingCapacity: true); lock.unlock()
            if !out.isEmpty {
                var sent = 0
                out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let base = raw.bindMemory(to: CChar.self).baseAddress!
                    while sent < out.count {
                        let w = libssh2_channel_write_ex(channel, 0, base + sent, out.count - sent)
                        if w == LIBSSH2_ERROR_EAGAIN { break }
                        if w < 0 { fail(session, "connection lost (write)"); break }
                        sent += w
                    }
                }
                if !isRunning() { break }
                if sent < out.count { // requeue the unsent tail
                    lock.lock(); pendingWrite = out.suffix(out.count - sent) + pendingWrite; lock.unlock()
                }
            }

            // Apply a pending resize.
            lock.lock(); let resize = pendingResize; pendingResize = nil; lock.unlock()
            if let resize { libssh2_channel_request_pty_size_ex(channel, resize.cols, resize.rows, 0, 0) }

            // Send a keepalive if one is due; a hard failure means a dead peer.
            var secondsToNext: Int32 = 0
            let ka = libssh2_keepalive_send(session, &secondsToNext)
            if ka < 0 && ka != Int32(LIBSSH2_ERROR_EAGAIN) { fail(session, "connection timed out"); break }

            waitSocket(session: session, timeoutMs: 30)
        }
        teardown()
        let reason: String? = { lock.lock(); defer { lock.unlock() }; return userClosed ? nil : closeReason }()
        onClosed?(reason)
    }

    /// Record a drop reason (libssh2's last error if available) and stop the loop.
    private func fail(_ session: OpaquePointer, _ fallback: String) {
        var message: UnsafeMutablePointer<CChar>?
        _ = libssh2_session_last_error(session, &message, nil, 0)
        let detail = message.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        lock.lock()
        if closeReason == nil { closeReason = detail ?? fallback }
        running = false
        lock.unlock()
    }

    private func waitSocket(session: OpaquePointer, timeoutMs: Int32) {
        let dir = libssh2_session_block_directions(session)
        var sshEvents: Int16 = 0
        if dir & BLOCK_INBOUND != 0 { sshEvents |= Int16(POLLIN) }
        if dir & BLOCK_OUTBOUND != 0 { sshEvents |= Int16(POLLOUT) }
        if sshEvents == 0 { sshEvents = Int16(POLLIN) }
        var pfds = [
            pollfd(fd: fd, events: sshEvents, revents: 0),
            pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
        ]
        let count: nfds_t = wakeRead >= 0 ? 2 : 1
        poll(&pfds, count, timeoutMs)
        if wakeRead >= 0, pfds[1].revents & Int16(POLLIN) != 0 {
            var trash = [UInt8](repeating: 0, count: 64)
            while Darwin.read(wakeRead, &trash, trash.count) > 0 {}
        }
    }

    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }
    private func stop() { lock.lock(); running = false; lock.unlock() }

    private func teardown() {
        if let channel { libssh2_channel_free(channel); self.channel = nil }
        if let session { libssh2_session_free(session); self.session = nil }
        if fd >= 0 { close(fd); fd = -1 }
        if wakeRead >= 0 { close(wakeRead); wakeRead = -1 }
        if wakeWrite >= 0 { close(wakeWrite); wakeWrite = -1 }
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
