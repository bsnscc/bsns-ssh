import Foundation
import CMosh

/// Drives a mosh (UDP) session: opens the client transport with the key the SSH
/// bootstrap obtained from `mosh-server`, pumps datagrams on a background thread,
/// and forwards the rendered framebuffer (ANSI) out via `onOutput`. Conforms to
/// `TerminalTransport`.
///
/// The run loop owns the client exclusively; `write`/`resize`/`disconnect` don't
/// touch it directly (that would either race the C client or, on a serial queue,
/// starve behind the loop). Instead they stage work under a lock and wake the
/// loop through a self-pipe, the same pattern as `SSHShell`.
final class MoshSession: TerminalTransport, @unchecked Sendable {
    var onOutput: (@Sendable (ArraySlice<UInt8>) -> Void)?
    var onClosed: (@Sendable (String?) -> Void)?
    /// Reports liveness transitions: `true` when the server has gone silent past
    /// the threshold (so the UI can show the session is stale rather than a
    /// reassuring green), `false` when contact resumes. mosh deliberately never
    /// self-closes on silence (it's built to roam), so this is the only signal a
    /// dead session gives us.
    var onLiveness: (@Sendable (Bool) -> Void)?
    private static let staleThreshold: TimeInterval = 8

    private let queue = DispatchQueue(label: "cc.bsns.ssh.mosh")
    private var client: OpaquePointer?
    private var lastContactAt = Date()
    private var staleReported = false

    private let lock = NSLock()
    private var pendingInput: [UInt8] = []
    private var pendingResize: (Int32, Int32)?
    private var stopRequested = false
    private var closeNotified = false

    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1

    func open(host: String, port: String, key: String, cols: Int32, rows: Int32) -> String? {
        guard let ip = Self.resolve(host) else { return "couldn't resolve \(host)" }
        let c = mosh_client_create(ip, port, key, cols, rows)
        if let err = mosh_client_last_error(c) { mosh_client_free(c); return String(cString: err) }
        client = c
        var fds: [Int32] = [-1, -1]
        pipe(&fds)
        wakeRead = fds[0]; wakeWrite = fds[1]
        queue.async { [weak self] in self?.runLoop() }
        return nil
    }

    func write(_ bytes: ArraySlice<UInt8>) {
        lock.lock(); pendingInput.append(contentsOf: bytes); lock.unlock()
        wake()
    }

    func resize(cols: Int32, rows: Int32) {
        lock.lock(); pendingResize = (cols, rows); lock.unlock()
        wake()
    }

    func disconnect() {
        lock.lock(); stopRequested = true; lock.unlock()
        wake()
    }

    private func wake() {
        if wakeWrite >= 0 { var b: UInt8 = 1; _ = Darwin.write(wakeWrite, &b, 1) }
    }

    private func runLoop() {
        guard let c = client else { return }
        while true {
            // Refresh mosh's frozen clock once per iteration. Without this every
            // send/ack timer stalls after the first packet and local input is
            // never transmitted (the server connects + paints once, then input
            // does nothing). See mosh_client_freeze_time / stmclient.cc.
            mosh_client_freeze_time()

            // Apply staged commands before blocking.
            lock.lock()
            let stop = stopRequested
            let input = pendingInput; pendingInput.removeAll(keepingCapacity: true)
            let resize = pendingResize; pendingResize = nil
            lock.unlock()

            if stop { break }
            if !input.isEmpty {
                input.withUnsafeBytes { raw in
                    mosh_client_push(c, raw.bindMemory(to: CChar.self).baseAddress, Int32(raw.count))
                }
            }
            if let (cols, rows) = resize { mosh_client_resize(c, cols, rows) }
            mosh_client_tick(c)

            var fds = [pollfd(fd: mosh_client_fd(c), events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            let timeout = max(1, min(mosh_client_wait_ms(c), 1000))
            poll(&fds, 2, Int32(timeout))

            if fds[1].revents & Int16(POLLIN) != 0 {            // drain the wake pipe
                var trash = [UInt8](repeating: 0, count: 64)
                _ = Darwin.read(wakeRead, &trash, trash.count)
            }
            if fds[0].revents & Int16(POLLIN) != 0 {            // a datagram arrived
                mosh_client_recv(c)
                lastContactAt = Date()
            }
            mosh_client_tick(c)
            if let ansi = mosh_client_drain_ansi(c) {
                let bytes = Array(String(cString: ansi).utf8)
                free(ansi)
                onOutput?(bytes[...])
            }
            // Flag staleness on transition (the loop wakes at least ~1/s, so this
            // is checked promptly without a separate timer).
            let stale = Date().timeIntervalSince(lastContactAt) > Self.staleThreshold
            if stale != staleReported { staleReported = stale; onLiveness?(stale) }
        }
        teardown()
    }

    private func teardown() {
        if let c = client { mosh_client_free(c); client = nil }
        if wakeRead >= 0 { close(wakeRead); wakeRead = -1 }
        if wakeWrite >= 0 { close(wakeWrite); wakeWrite = -1 }
        lock.lock(); let notify = !closeNotified; closeNotified = true; lock.unlock()
        if notify { onClosed?(nil) }   // user-initiated stop = clean
    }

    /// Resolve a host (name or IP literal) to a numeric address for the mosh
    /// transport, which connects to a literal. Prefers the first result.
    private static func resolve(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_DGRAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen,
                             &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
        guard rc == 0 else { return nil }
        return String(cString: buf)
    }
}
