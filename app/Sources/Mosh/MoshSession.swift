import Foundation
import CMosh

/// Drives a mosh (UDP) session: opens the client transport with the key the SSH
/// bootstrap obtained from `mosh-server`, pumps datagrams on a background queue,
/// and forwards the rendered framebuffer (ANSI) out via `onOutput`. Input goes in
/// through `write`. Conforms to `TerminalTransport` so a `TerminalSession` drives
/// it the same way it drives an `SSHShell`.
final class MoshSession: TerminalTransport, @unchecked Sendable {
    var onOutput: (@Sendable (ArraySlice<UInt8>) -> Void)?
    var onClosed: (@Sendable (String?) -> Void)?

    private let queue = DispatchQueue(label: "cc.bsns.ssh.mosh")
    private var client: OpaquePointer?
    private var running = false

    /// Open a mosh client to `host` (resolved to an IP) on `port`, using the
    /// base64 key from the `MOSH CONNECT` line. Returns nil on success or an
    /// error string. mosh's own transport keeps the session alive across network
    /// changes, so there's no separate keepalive here.
    func open(host: String, port: String, key: String, cols: Int32, rows: Int32) -> String? {
        guard let ip = Self.resolve(host) else { return "couldn't resolve \(host)" }
        let c = mosh_client_create(ip, port, key, cols, rows)
        if let err = mosh_client_last_error(c) { mosh_client_free(c); return String(cString: err) }
        client = c
        running = true
        queue.async { [weak self] in self?.runLoop() }
        return nil
    }

    func write(_ bytes: ArraySlice<UInt8>) {
        queue.async { [weak self] in
            guard let self, let c = self.client else { return }
            Array(bytes).withUnsafeBytes { raw in
                mosh_client_push(c, raw.bindMemory(to: CChar.self).baseAddress, Int32(raw.count))
            }
            mosh_client_tick(c)
        }
    }

    func resize(cols: Int32, rows: Int32) {
        queue.async { [weak self] in
            guard let self, let c = self.client else { return }
            mosh_client_resize(c, cols, rows); mosh_client_tick(c)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.running else { return }
            self.running = false
            if let c = self.client { mosh_client_free(c); self.client = nil }
            self.onClosed?(nil)   // user-initiated = clean
        }
    }

    private func runLoop() {
        guard let c = client else { return }
        var fds = [pollfd(fd: mosh_client_fd(c), events: Int16(POLLIN), revents: 0)]
        while running {
            mosh_client_tick(c)
            let timeout = max(1, min(mosh_client_wait_ms(c), 1000))
            poll(&fds, 1, Int32(timeout))
            if !running { break }
            if fds[0].revents & Int16(POLLIN) != 0 { mosh_client_recv(c) }
            mosh_client_tick(c)
            if let ansi = mosh_client_drain_ansi(c) {
                let bytes = Array(String(cString: ansi).utf8)
                free(ansi)
                onOutput?(bytes[...])
            }
        }
    }

    /// Resolve a host (name or IP literal) to a numeric address string for the
    /// mosh transport, which connects to a literal. Prefers the first result.
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
