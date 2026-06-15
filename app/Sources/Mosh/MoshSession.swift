import Foundation
import CMosh

/// Drives a mosh (UDP) session: opens the client transport with the key the SSH
/// bootstrap obtained from `mosh-server`, pumps datagrams on a background queue,
/// and forwards the rendered framebuffer (ANSI) out via `onOutput`. Input goes in
/// through `write`.
///
/// NOTE: bootstrap (running `mosh-server new` over SSH and parsing `MOSH CONNECT`)
/// and the SwiftTerm wiring are the next step; this drives the C client and the
/// run loop. Validated to compile + link; live behavior needs a real mosh-server.
final class MoshSession: @unchecked Sendable {
    var onOutput: (@Sendable (ArraySlice<UInt8>) -> Void)?

    private let queue = DispatchQueue(label: "cc.bsns.ssh.mosh")
    private var client: OpaquePointer?
    private var running = false

    /// Open a mosh client. `key` is the base64 key from the `MOSH CONNECT` line.
    func open(ip: String, port: String, key: String, cols: Int32, rows: Int32) -> String? {
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

    func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            if let c = self.client { mosh_client_free(c); self.client = nil }
        }
    }

    private func runLoop() {
        guard let c = client else { return }
        var fds = [pollfd(fd: mosh_client_fd(c), events: Int16(POLLIN), revents: 0)]
        while running {
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
}
