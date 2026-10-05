import Foundation
import Darwin
import BsnsSSHCore

/// Serves the agent to other programs on this Mac over a Unix socket, speaking
/// the standard SSH agent protocol — so `ssh`, `git`, `scp` and `rsync` in any
/// terminal can authenticate with the keys held here, including the ones that
/// live in the Secure Enclave.
///
/// The socket is private to the user (0600 in a 0700 directory) and every
/// connection's peer is checked to be the same user. Which keys a connection
/// may see is decided by `exposing`; the protocol itself is handled by
/// `AgentClientConnection` in the core, so this file is only the plumbing that
/// would differ on another platform.
final class AgentSocketServer: @unchecked Sendable {
    /// Short and free of spaces, so it can be pasted into an ssh config or a
    /// shell profile without quoting.
    static var socketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bsns/agent.sock")
    }

    enum ServerError: LocalizedError {
        case pathTooLong, system(String, Int32)
        var errorDescription: String? {
            switch self {
            case .pathTooLong: return "The socket path is too long."
            case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    private let agent: Agent
    private let isExposed: (@Sendable (any KeyBackend) -> Bool)?
    private let hostName: @Sendable (Data) -> String?
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    /// Accepted connections still being served. Stopping the server ends them
    /// too: a program that connected while the agent was on must not keep its
    /// access — or the key filter it connected under — after it is turned off
    /// or restricted.
    private var clients: Set<Int32> = []

    init(agent: Agent, exposing isExposed: (@Sendable (any KeyBackend) -> Bool)?,
         hostName: @escaping @Sendable (Data) -> String?) {
        self.agent = agent
        self.isExposed = isExposed
        self.hostName = hostName
    }

    func start() throws {
        let url = Self.socketURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        // A socket file left by a previous run would make bind fail.
        unlink(url.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.system("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = url.path
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); throw ServerError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
        }
        // Created 0600 from the start rather than tightened afterwards.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0 else { let code = errno; close(fd); throw ServerError.system("bind", code) }
        guard listen(fd, 16) == 0 else { let code = errno; close(fd); throw ServerError.system("listen", code) }

        lock.withLock { listenFD = fd }
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        let (fd, open): (Int32, Set<Int32>) = lock.withLock {
            let fd = listenFD
            listenFD = -1
            return (fd, clients)
        }
        // Each serving thread owns its descriptor and closes it; shutting the
        // connection down here wakes that thread and makes any further read or
        // write fail, including the answer to a request still awaiting approval.
        for client in open { shutdown(client, SHUT_RDWR) }
        guard fd >= 0 else { return }
        close(fd)
        unlink(Self.socketURL.path)
    }

    /// Whether `client` is still one this server answers.
    private func isLive(_ client: Int32) -> Bool {
        lock.withLock { listenFD >= 0 && clients.contains(client) }
    }

    private func release(_ client: Int32) {
        lock.withLock { _ = clients.remove(client) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // the listening socket was closed
            }
            // Only this user's processes. The directory and socket modes already
            // say so; this is the check that doesn't depend on them.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            // A client that goes away while its request waits for approval must
            // get a failed write, not a signal that takes the whole app down.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Registered only while the server is still running: a connection
            // that slipped in as it stopped is dropped.
            let admitted: Bool = lock.withLock {
                guard listenFD >= 0 else { return false }
                clients.insert(client)
                return true
            }
            guard admitted else { close(client); continue }
            let requester = Self.describePeer(client)
            Thread.detachNewThread { [weak self, agent, isExposed, hostName] in
                Self.serve(client, connection: AgentClientConnection(agent: agent, requester: requester,
                                                                     exposing: isExposed, hostName: hostName),
                           isLive: { self?.isLive(client) ?? false },
                           finished: { self?.release(client) })
            }
        }
    }

    /// One client, start to finish, on its own thread: blocking reads, and each
    /// request answered before the next is read (the protocol is strictly
    /// request/response).
    private static func serve(_ fd: Int32, connection: AgentClientConnection,
                              isLive: @escaping @Sendable () -> Bool, finished: @escaping @Sendable () -> Void) {
        // Unregistered before the descriptor is closed, so `stop` can never
        // shut down a number that has since been reused for something else.
        defer { finished(); close(fd) }
        var reader = AgentFrameReader()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0, isLive() else { return }
            reader.append(Data(buffer[0..<n]))
            while true {
                let payload: Data?
                do { payload = try reader.next() } catch { return }
                guard let payload else { break }
                // Bridge to the async agent from this dedicated thread. A
                // signature may wait on Touch ID, so there is no timeout here.
                let done = DispatchSemaphore(value: 0)
                let box = ResponseBox()
                Task {
                    box.value = await connection.respond(to: payload)
                    done.signal()
                }
                done.wait()
                // Turned off while this was being answered: the answer isn't sent.
                guard isLive(), writeAll(fd, AgentFrameReader.frame(box.value)) else { return }
            }
        }
    }

    private final class ResponseBox: @unchecked Sendable { var value = Data() }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    /// The program on the other end, and what started it: "ssh (git)". The
    /// parent matters because ssh is usually run on something's behalf.
    private static func describePeer(_ fd: Int32) -> String? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        guard let name = processName(pid) else { return nil }
        var info = proc_bsdinfo()
        let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        if got > 0, let parent = processName(pid_t(info.pbi_ppid)),
           parent != name, !["zsh", "bash", "sh", "fish", "login", "launchd"].contains(parent) {
            return "\(name) (\(parent))"
        }
        return name
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
