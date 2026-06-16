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
    // A ProxyJump bastion whose own host key isn't trusted yet — carries the
    // bastion's host/port so the UI can prompt + trust under the right identifier
    // (vs. the target, which is verified separately through the tunnel).
    case unknownJumpHostKey(HostKey, host: String, port: UInt16)
    case jumpHostKeyMismatch(String, String)
    case noIdentities, authFailed(String)
    case channelOpenFailed, ptyFailed, shellFailed, execFailed(String)
    case algorithmPolicyFailed
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

    // Local (-L) port forwarding, multiplexed over this session. All libssh2
    // channel ops happen on `queue`; listening sockets are added under `lock`.
    private struct Listener { let id: UUID; let fd: Int32; let destHost: String; let destPort: UInt16 }
    private struct PendingOpen { let localFd: Int32; let destHost: String; let destPort: UInt16 }

    /// A FIFO byte buffer that consumes from the front in amortized O(1) — it
    /// advances a head index and only compacts the backing array periodically,
    /// instead of `removeFirst(n)` shifting every remaining byte each drain.
    private struct ByteQueue {
        private var bytes: [UInt8] = []
        private var head = 0
        var count: Int { bytes.count - head }
        var isEmpty: Bool { head >= bytes.count }

        mutating func append(_ slice: ArraySlice<UInt8>) {
            if isEmpty { bytes.removeAll(keepingCapacity: true); head = 0 }
            bytes.append(contentsOf: slice)
        }

        /// The unconsumed bytes, for writing out to a socket/channel.
        func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R {
            bytes.withUnsafeBytes { body(UnsafeRawBufferPointer(rebasing: $0[head...])) }
        }

        mutating func consume(_ n: Int) {
            head += n
            if isEmpty { bytes.removeAll(keepingCapacity: true); head = 0 }
            else if head > 65536 { bytes.removeFirst(head); head = 0 }  // amortized compaction
        }
    }

    // Per-direction cap on a forward's buffer. Once a direction is this full we
    // stop reading its source, so a slow consumer applies backpressure (TCP /
    // libssh2 window) instead of letting the buffer grow without bound.
    private static let forwardBufferCap = 1 << 20   // 1 MiB

    private final class ForwardConn {
        let localFd: Int32
        let channel: OpaquePointer
        var toChannel = ByteQueue()   // buffered local → remote
        var toLocal = ByteQueue()     // buffered remote → local
        var localClosed = false       // local socket hit EOF/error
        var channelEOF = false        // remote sent EOF
        var sentChannelEOF = false    // we forwarded local EOF to the channel
        init(localFd: Int32, channel: OpaquePointer) { self.localFd = localFd; self.channel = channel }
    }
    private var listeners: [Listener] = []          // guarded by lock
    private var removedListenerIDs: [UUID] = []      // guarded by lock
    private var pendingOpens: [PendingOpen] = []     // queue-only
    private var forwardConns: [ForwardConn] = []     // queue-only
    private var bridge: AgentSignBridge? // kept alive for the auth call
    // Self-pipe so write/resize wake the poll loop immediately instead of
    // waiting out the poll timeout — keystrokes are sent with no added latency.
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1

    /// One ProxyJump hop.
    public struct JumpHop: Sendable { public let host: String; public let port: UInt16; public let user: String
        public init(host: String, port: UInt16, user: String) { self.host = host; self.port = port; self.user = user } }

    // ProxyJump tunnel: a session to the bastion + a direct-tcpip channel to the
    // target, relayed over a socketpair so the target handshake runs end-to-end
    // (the target host key is verified through the tunnel). Pumped on its own queue.
    private var jumpSession: OpaquePointer?
    private var jumpChannel: OpaquePointer?
    private var jumpFd: Int32 = -1
    private var jumpPumpFd: Int32 = -1
    private let jumpQueue = DispatchQueue(label: "cc.bsns.ssh.jump")
    private var jumpStop = false

    public init() {}

    /// Connect, authenticate through `agent`, open a PTY + shell, and start the
    /// I/O loop. Returns once the shell is live (output then streams via
    /// `onOutput`). `knownHosts` mismatches are refused.
    public func connect(host: String, port: UInt16, user: String, agent: Agent,
                        cols: Int32 = 80, rows: Int32 = 24,
                        knownHosts: KnownHosts = KnownHosts(),
                        password: String? = nil,
                        jump: JumpHop? = nil) async throws {
        let usingPassword = !(password ?? "").isEmpty
        let identities = await agent.identities()
        guard usingPassword || !identities.isEmpty else { throw SSHShellError.noIdentities }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.setup(host: host, port: port, user: user, agent: agent,
                                   identities: identities, cols: cols, rows: rows,
                                   knownHosts: knownHosts, password: password, jump: jump)
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

    /// Start a local (-L) forward: listen on `bindAddress:listenPort` on this
    /// device and tunnel each connection to `destHost:destPort` from the SSH
    /// server. Returns nil on success, or an error string if the bind failed.
    public func addLocalForward(id: UUID, bindAddress: String, listenPort: UInt16,
                                destHost: String, destPort: UInt16) -> String? {
        guard let fd = Self.listenSocket(bindAddress: bindAddress, port: listenPort) else {
            return "couldn't bind \(bindAddress):\(listenPort) — port in use?"
        }
        lock.lock(); listeners.append(Listener(id: id, fd: fd, destHost: destHost, destPort: destPort)); lock.unlock()
        wake()
        return nil
    }

    public func removeLocalForward(id: UUID) {
        lock.lock(); removedListenerIDs.append(id); lock.unlock()
        wake()
    }

    private func wake() {
        if wakeWrite >= 0 { var byte: UInt8 = 1; _ = Darwin.write(wakeWrite, &byte, 1) }
    }

    // MARK: setup (blocking)

    /// libssh2's global init is process-wide; do it exactly once (this static is
    /// initialized lazily + thread-safely) and never call libssh2_exit, since
    /// other sessions may still be live.
    private static let libssh2Ready: Bool = (libssh2_init(0) == 0)

    private func setup(host: String, port: UInt16, user: String, agent: Agent,
                       identities: [SSHPublicKey], cols: Int32, rows: Int32, knownHosts: KnownHosts,
                       password: String?, jump: JumpHop? = nil) throws {
        guard Self.libssh2Ready else { throw SSHShellError.libssh2Init }
        // Direct, or tunneled through a bastion (ProxyJump). The tunnel fd carries
        // the end-to-end handshake, so the target host key below is the real target's.
        let fd: Int32
        if let jump {
            // The bastion authenticates with a key/agent only — never `password`,
            // which is the TARGET's and must not be offered to the jump host.
            fd = try openJumpTunnel(jump, targetHost: host, targetPort: port,
                                    agent: agent, identities: identities,
                                    knownHosts: knownHosts)
        } else {
            guard let direct = Self.tcpConnect(host: host, port: port) else { throw SSHShellError.connectFailed }
            fd = direct
        }
        self.fd = fd
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else { throw SSHShellError.sessionInit }
        self.session = session
        libssh2_session_set_blocking(session, 1)
        try Self.applyAlgorithmPolicy(session)
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

        let termType = UserDefaults.standard.string(forKey: "session.terminalType") ?? "xterm-256color"
        let pty = termType.withCString {
            libssh2_channel_request_pty_ex(channel, $0, UInt32(strlen($0)), nil, 0, cols, rows, 0, 0)
        }
        guard pty == 0 else { throw SSHShellError.ptyFailed }
        guard libssh2_channel_process_startup(channel, "shell", 5, nil, 0) == 0 else { throw SSHShellError.shellFailed }

        libssh2_session_set_blocking(session, 0) // non-blocking for the I/O loop
        // Server-replied keepalives keep NAT/firewall mappings alive and let us
        // notice a dead peer instead of hanging on a silent socket.
        let keepAlive = UserDefaults.standard.integer(forKey: "session.keepAliveInterval")
        libssh2_keepalive_config(session, 1, UInt32(keepAlive > 0 ? keepAlive : 30))

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

    /// Establish the bastion session + a direct-tcpip channel to the target, relayed
    /// over a socketpair. Returns the target-side fd for the end-to-end handshake
    /// (so the caller's handshake + host-key check apply to the real target). The
    /// bastion's OWN host key is verified against `knownHosts` BEFORE we authenticate
    /// to it — a spoofed bastion can't collect an auth attempt before it's trusted.
    /// The bastion authenticates by key/agent only: the target's password is never
    /// offered to it (that password is used end-to-end against the target instead).
    private func openJumpTunnel(_ jump: JumpHop, targetHost: String, targetPort: UInt16,
                                agent: Agent, identities: [SSHPublicKey],
                                knownHosts: KnownHosts) throws -> Int32 {
        guard let bfd = Self.tcpConnect(host: jump.host, port: jump.port) else { throw SSHShellError.connectFailed }
        guard let bsession = libssh2_session_init_ex(nil, nil, nil, nil) else { close(bfd); throw SSHShellError.sessionInit }
        libssh2_session_set_blocking(bsession, 1)
        do {
            try Self.applyAlgorithmPolicy(bsession)
            guard libssh2_session_handshake(bsession, bfd) == 0 else { throw SSHShellError.handshakeFailed }
            // Trust the bastion BEFORE sending any auth (its own TOFU decision).
            let bastionKey = try Self.presentedHostKey(bsession)
            switch knownHosts.verify(host: jump.host, port: jump.port, key: bastionKey) {
            case .trusted: break
            case .unknown: throw SSHShellError.unknownJumpHostKey(bastionKey, host: jump.host, port: jump.port)
            case let .mismatch(stored, presented): throw SSHShellError.jumpHostKeyMismatch(stored, presented)
            }
            try Self.authenticatePublicKey(bsession, user: jump.user, identities: identities, agent: agent, host: jump.host)
            guard let channel = targetHost.withCString({
                libssh2_channel_direct_tcpip_ex(bsession, $0, Int32(targetPort), "127.0.0.1", 22)
            }) else { throw SSHShellError.channelOpenFailed }
            var sp: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sp) == 0 else {
                libssh2_channel_free(channel); throw SSHShellError.connectFailed
            }
            _ = fcntl(sp[1], F_SETFL, O_NONBLOCK)
            libssh2_session_set_blocking(bsession, 0)
            libssh2_channel_set_blocking(channel, 0)
            jumpSession = bsession; jumpChannel = channel; jumpFd = bfd; jumpPumpFd = sp[1]
            lock.lock(); jumpStop = false; lock.unlock()
            jumpQueue.async { [weak self] in self?.jumpPump() }
            return sp[0]   // target-side fd
        } catch {
            libssh2_session_free(bsession); close(bfd); throw error
        }
    }

    /// Relay bytes between the local socketpair end and the bastion tunnel channel
    /// until either side closes. Owns the bastion session exclusively while it runs.
    private func jumpPump() {
        guard let channel = jumpChannel else { return }
        var buf = [UInt8](repeating: 0, count: 16384)
        while !(lock.withLock { jumpStop }) {
            var idle = true
            let n = buf.withUnsafeMutableBytes {
                libssh2_channel_read_ex(channel, 0, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count)
            }
            if n > 0 {
                idle = false
                var off = 0
                while off < n {
                    let w = buf.withUnsafeBytes { Darwin.write(jumpPumpFd, $0.baseAddress!.advanced(by: off), n - off) }
                    if w < 0 { if errno == EINTR { continue }; lock.withLock { jumpStop = true }; break }
                    off += w
                }
            } else if n != LIBSSH2_ERROR_EAGAIN && (n < 0 || libssh2_channel_eof(channel) != 0) {
                lock.withLock { jumpStop = true }; break
            }
            let m = buf.withUnsafeMutableBytes { Darwin.read(jumpPumpFd, $0.baseAddress, $0.count) }
            if m > 0 {
                idle = false
                var off = 0
                while off < m {
                    let w = buf.withUnsafeBytes {
                        libssh2_channel_write_ex(channel, 0, $0.baseAddress!.advanced(by: off).assumingMemoryBound(to: CChar.self), m - off)
                    }
                    if w == LIBSSH2_ERROR_EAGAIN { continue }
                    if w < 0 { lock.withLock { jumpStop = true }; break }
                    off += w
                }
            } else if m == 0 {
                lock.withLock { jumpStop = true }; break
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                lock.withLock { jumpStop = true }; break
            }
            if idle { usleep(2000) }
        }
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

    /// Run a command over SSH (agent or password auth) and return its stdout.
    /// Used to bootstrap mosh (`mosh-server new` prints `MOSH CONNECT ...`).
    public static func execCapturing(host: String, port: UInt16, user: String,
                                     agent: Agent?, password: String?,
                                     command: String, knownHosts: KnownHosts) async throws -> String {
        let identities = agent == nil ? [] : await agent!.identities()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try execBlocking(host: host, port: port, user: user,
                                                            agent: agent, identities: identities,
                                                            password: password, command: command,
                                                            knownHosts: knownHosts))
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Open a socket, handshake, verify the host key, and authenticate — the
    /// shared prologue for any libssh2 use (shell, exec, SFTP). Returns the
    /// connected socket + authenticated session; the caller owns teardown
    /// (`libssh2_session_disconnect`/`_free` + `close`). Throws the same
    /// host-key / auth errors as the shell, so callers can drive the TOFU prompt.
    /// Must run off the main thread (the agent biometric prompt blocks here).
    public static func openAuthenticatedSession(
        host: String, port: UInt16, user: String, agent: Agent?, identities: [SSHPublicKey],
        password: String?, knownHosts: KnownHosts
    ) throws -> (fd: Int32, session: OpaquePointer) {
        guard libssh2Ready else { throw SSHShellError.libssh2Init }
        guard let fd = tcpConnect(host: host, port: port) else { throw SSHShellError.connectFailed }
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            close(fd); throw SSHShellError.sessionInit
        }
        libssh2_session_set_blocking(session, 1)
        try applyAlgorithmPolicy(session)
        do {
            guard libssh2_session_handshake(session, fd) == 0 else { throw SSHShellError.handshakeFailed }
            let hostKey = try presentedHostKey(session)
            switch knownHosts.verify(host: host, port: port, key: hostKey) {
            case .trusted: break
            case .unknown: throw SSHShellError.unknownHostKey(hostKey)
            case let .mismatch(stored, presented): throw SSHShellError.hostKeyMismatch(stored, presented)
            }
            if let password, !password.isEmpty {
                try passwordAuth(session, user: user, password: password)
            } else if let agent {
                try authenticatePublicKey(session, user: user, identities: identities, agent: agent, host: host)
            } else {
                throw SSHShellError.noIdentities
            }
        } catch {
            libssh2_session_free(session); close(fd); throw error
        }
        return (fd, session)
    }

    /// Restrict the SSH handshake to modern algorithms — no SHA-1 host keys,
    /// CBC ciphers, 3DES/arcfour, or HMAC-SHA1. Fail closed: if libssh2 can't
    /// honor one of these lists (none of our algorithms are available for a
    /// category), we refuse rather than silently fall back to its weaker
    /// defaults, since the security claim depends on the allowlist holding.
    static func applyAlgorithmPolicy(_ session: OpaquePointer) throws {
        let prefs: [(Int32, String)] = [
            (0 /* KEX */, "curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group16-sha512,diffie-hellman-group14-sha256"),
            (1 /* HOSTKEY */, "ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-512,rsa-sha2-256"),
            (2 /* CRYPT_CS */, "aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"),
            (3 /* CRYPT_SC */, "aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"),
            (4 /* MAC_CS */, "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512"),
            (5 /* MAC_SC */, "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512"),
        ]
        for (method, list) in prefs {
            let rc = list.withCString { libssh2_session_method_pref(session, method, $0) }
            if rc != 0 { throw SSHShellError.algorithmPolicyFailed }
        }
    }

    private static func authenticatePublicKey(_ session: OpaquePointer, user: String,
                                              identities: [SSHPublicKey], agent: Agent, host: String) throws {
        var keepAlive: [AgentSignBridge] = []   // hold bridges for the duration of the call
        var lastError = "no identity accepted"
        for identity in identities {
            let bridge = AgentSignBridge(agent: agent, publicKeyBlob: identity.blob,
                                         signContext: SignContext(host: host, purpose: .sshUserAuth))
            keepAlive.append(bridge)
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

    private static func execBlocking(host: String, port: UInt16, user: String,
                                     agent: Agent?, identities: [SSHPublicKey], password: String?,
                                     command: String, knownHosts: KnownHosts) throws -> String {
        guard libssh2Ready else { throw SSHShellError.libssh2Init }
        guard let fd = tcpConnect(host: host, port: port) else { throw SSHShellError.connectFailed }
        defer { close(fd) }
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else { throw SSHShellError.sessionInit }
        defer { libssh2_session_free(session) }
        libssh2_session_set_blocking(session, 1)
        try applyAlgorithmPolicy(session)
        guard libssh2_session_handshake(session, fd) == 0 else { throw SSHShellError.handshakeFailed }

        let hostKey = try presentedHostKey(session)
        switch knownHosts.verify(host: host, port: port, key: hostKey) {
        case .trusted: break
        case .unknown: throw SSHShellError.unknownHostKey(hostKey)
        case let .mismatch(stored, presented): throw SSHShellError.hostKeyMismatch(stored, presented)
        }

        if let password, !password.isEmpty {
            try passwordAuth(session, user: user, password: password)
        } else if let agent {
            try authenticatePublicKey(session, user: user, identities: identities, agent: agent, host: host)
        } else {
            throw SSHShellError.noIdentities
        }

        guard let channel = libssh2_channel_open_ex(session, "session", 7, 2 * 1024 * 1024, 32768, nil, 0) else {
            throw SSHShellError.channelOpenFailed
        }
        defer { libssh2_channel_free(channel) }
        let startup = command.withCString {
            libssh2_channel_process_startup(channel, "exec", 4, $0, UInt32(strlen($0)))
        }
        guard startup == 0 else { throw SSHShellError.execFailed("process_startup rc=\(startup)") }

        var out = [UInt8]()
        var buffer = [CChar](repeating: 0, count: 4096)
        while true {
            let n = libssh2_channel_read_ex(channel, 0, &buffer, buffer.count)
            if n > 0 { out.append(contentsOf: buffer[0 ..< Int(n)].map { UInt8(bitPattern: $0) }) }
            else { break }
        }
        libssh2_channel_close(channel)
        return String(decoding: out, as: UTF8.self)
    }

    private static func runExec(host: String, port: UInt16, user: String, password: String,
                                command: String, knownHosts: KnownHosts) throws {
        guard libssh2Ready else { throw SSHShellError.libssh2Init }
        guard let fd = tcpConnect(host: host, port: port) else { throw SSHShellError.connectFailed }
        defer { close(fd) }
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else { throw SSHShellError.sessionInit }
        defer { libssh2_session_free(session) }
        libssh2_session_set_blocking(session, 1)
        try applyAlgorithmPolicy(session)
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

            serviceForwards(session: session)

            waitSocket(session: session, timeoutMs: 30)
        }
        teardownForwards()
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
        // Also wake on forward-listener accepts and forwarded-connection I/O.
        lock.lock(); let ls = listeners; lock.unlock()
        for l in ls { pfds.append(pollfd(fd: l.fd, events: Int16(POLLIN), revents: 0)) }
        for c in forwardConns {
            var ev: Int16 = 0
            if !c.localClosed { ev |= Int16(POLLIN) }
            if !c.toLocal.isEmpty { ev |= Int16(POLLOUT) }
            if ev != 0 { pfds.append(pollfd(fd: c.localFd, events: ev, revents: 0)) }
        }
        poll(&pfds, nfds_t(pfds.count), timeoutMs)
        if wakeRead >= 0, pfds[1].revents & Int16(POLLIN) != 0 {
            var trash = [UInt8](repeating: 0, count: 64)
            while Darwin.read(wakeRead, &trash, trash.count) > 0 {}
        }
    }

    // MARK: local port forwarding (serviced on `queue`)

    private func serviceForwards(session: OpaquePointer) {
        // Apply pending removals.
        lock.lock(); let removals = removedListenerIDs; removedListenerIDs.removeAll(); lock.unlock()
        for id in removals {
            lock.lock()
            if let idx = listeners.firstIndex(where: { $0.id == id }) {
                close(listeners[idx].fd); listeners.remove(at: idx)
            }
            lock.unlock()
        }

        // Accept any waiting local connections.
        lock.lock(); let current = listeners; lock.unlock()
        for l in current {
            while true {
                let cfd = accept(l.fd, nil, nil)
                if cfd < 0 { break }
                _ = fcntl(cfd, F_SETFL, O_NONBLOCK)
                pendingOpens.append(PendingOpen(localFd: cfd, destHost: l.destHost, destPort: l.destPort))
            }
        }

        // Try opening a direct-tcpip channel for each pending connection.
        if !pendingOpens.isEmpty {
            var stillPending: [PendingOpen] = []
            for p in pendingOpens {
                let channel = p.destHost.withCString {
                    libssh2_channel_direct_tcpip_ex(session, $0, Int32(p.destPort), "127.0.0.1", 0)
                }
                if let channel {
                    libssh2_channel_set_blocking(channel, 0)
                    forwardConns.append(ForwardConn(localFd: p.localFd, channel: channel))
                } else if libssh2_session_last_errno(session) == Int32(LIBSSH2_ERROR_EAGAIN) {
                    stillPending.append(p)        // not ready yet — retry next tick
                } else {
                    close(p.localFd)               // server refused the connection
                }
            }
            pendingOpens = stillPending
        }

        // Pump each active connection both ways; drop the closed ones.
        guard !forwardConns.isEmpty else { return }
        var buf = [UInt8](repeating: 0, count: 32768)
        forwardConns = forwardConns.filter { pumpForward($0, buf: &buf) }
    }

    /// Move bytes in both directions for one forwarded connection. Returns false
    /// once both halves are done (the channel + socket are then closed).
    private func pumpForward(_ c: ForwardConn, buf: inout [UInt8]) -> Bool {
        let cap = Self.forwardBufferCap

        // remote → buffer (stop reading while the local side is backed up)
        if !c.channelEOF {
            while c.toLocal.count < cap {
                let n = buf.withUnsafeMutableBytes {
                    libssh2_channel_read_ex(c.channel, 0, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count)
                }
                if n > 0 { c.toLocal.append(buf[0 ..< Int(n)]) }
                else if n == LIBSSH2_ERROR_EAGAIN { break }
                else { c.channelEOF = true; break }   // 0 = EOF, <0 = error
            }
        }
        if libssh2_channel_eof(c.channel) != 0 { c.channelEOF = true }

        // buffer → local socket
        while !c.toLocal.isEmpty {
            let w = c.toLocal.withUnsafeBytes { Darwin.write(c.localFd, $0.baseAddress, $0.count) }
            if w > 0 { c.toLocal.consume(w) }
            else { if w < 0 && errno != EAGAIN && errno != EWOULDBLOCK { c.localClosed = true }; break }
        }

        // local socket → buffer (stop reading while the remote side is backed up)
        if !c.localClosed {
            while c.toChannel.count < cap {
                let n = buf.withUnsafeMutableBytes { Darwin.read(c.localFd, $0.baseAddress, $0.count) }
                if n > 0 { c.toChannel.append(buf[0 ..< n]) }
                else if n == 0 { c.localClosed = true; break }
                else { if errno != EAGAIN && errno != EWOULDBLOCK { c.localClosed = true }; break }
            }
        }

        // buffer → remote
        while !c.toChannel.isEmpty {
            let w = c.toChannel.withUnsafeBytes {
                libssh2_channel_write_ex(c.channel, 0, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count)
            }
            if w > 0 { c.toChannel.consume(w) } else { break }   // EAGAIN/error: retry next tick
        }

        // Forward a half-close once our outbound buffer is flushed.
        if c.localClosed && c.toChannel.isEmpty && !c.sentChannelEOF {
            libssh2_channel_send_eof(c.channel); c.sentChannelEOF = true
        }

        let remoteDone = c.channelEOF && c.toLocal.isEmpty
        let localDone = c.localClosed && c.toChannel.isEmpty
        if remoteDone && localDone {
            libssh2_channel_close(c.channel)
            libssh2_channel_free(c.channel)
            close(c.localFd)
            return false
        }
        return true
    }

    private func teardownForwards() {
        for c in forwardConns { libssh2_channel_free(c.channel); close(c.localFd) }
        forwardConns.removeAll()
        for p in pendingOpens { close(p.localFd) }
        pendingOpens.removeAll()
        lock.lock(); let ls = listeners; listeners.removeAll(); removedListenerIDs.removeAll(); lock.unlock()
        for l in ls { close(l.fd) }
    }

    private static func listenSocket(bindAddress: String, port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, bindAddress, &addr.sin_addr) == 1 else { close(fd); return nil }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return nil }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return fd
    }

    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }
    private func stop() { lock.lock(); running = false; lock.unlock() }

    private func teardown() {
        if let channel { libssh2_channel_free(channel); self.channel = nil }
        if let session { libssh2_session_free(session); self.session = nil }
        if fd >= 0 { close(fd); fd = -1 }
        if wakeRead >= 0 { close(wakeRead); wakeRead = -1 }
        if wakeWrite >= 0 { close(wakeWrite); wakeWrite = -1 }
        // Tear down the ProxyJump tunnel: stop the pump (drain its queue so it has
        // exited), then free the bastion channel + session.
        if jumpSession != nil || jumpChannel != nil {
            lock.lock(); jumpStop = true; lock.unlock()
            jumpQueue.sync {}
            if let jumpChannel { libssh2_channel_free(jumpChannel); self.jumpChannel = nil }
            if let jumpSession { libssh2_session_free(jumpSession); self.jumpSession = nil }
            if jumpPumpFd >= 0 { close(jumpPumpFd); jumpPumpFd = -1 }
            if jumpFd >= 0 { close(jumpFd); jumpFd = -1 }
        }
        // No libssh2_exit() here — the global init is process-wide (see libssh2Ready).
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

    /// Resolve `host` (DNS name, IPv4, or IPv6) and connect, trying each returned
    /// address in turn.
    private static func tcpConnect(host: String, port: UInt16) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC          // IPv4 or IPv6
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0 else { return nil }
        defer { freeaddrinfo(res) }
        var ai = res
        while let info = ai {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { return fd }
                close(fd)
            }
            ai = info.pointee.ai_next
        }
        return nil
    }
}
