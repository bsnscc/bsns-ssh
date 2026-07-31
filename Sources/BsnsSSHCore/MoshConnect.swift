import Foundation

/// The UDP port + session key that `mosh-server new` prints on its first line:
///
///     MOSH CONNECT 60001 4NeCCgvZFe2RnPgrcU1PTw
///
/// The key is a 22-char base64 (16-byte AES key, no padding). `mosh` passes it
/// to the client in the `MOSH_KEY` environment variable; we hand it straight to
/// the transport. Parsing is pure so it can be unit-tested without a server.
public struct MoshConnect: Equatable, Sendable {
    public let port: String
    public let key: String
    /// The PID `mosh-server` reports as it daemonizes (`[mosh-server detached,
    /// pid = 1234]`, printed on **stderr**, so the caller must capture that
    /// stream too). We remember it per session: a mosh-server we abandon — an
    /// app relaunch, a reconnect after a failed resume — otherwise lives
    /// forever holding a PTY, and enough of them exhaust the host. nil when the
    /// line wasn't in the captured output (older server, stderr not captured).
    public let pid: Int32?

    public init(port: String, key: String, pid: Int32? = nil) {
        self.port = port
        self.key = key
        self.pid = pid
    }

    /// Extract the connect line from `mosh-server` stdout. Returns nil if no
    /// well-formed `MOSH CONNECT <port> <key>` line is present (e.g. the binary
    /// is missing, or the command printed an error instead).
    public static func parse(_ serverOutput: String) -> MoshConnect? {
        for raw in serverOutput.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("MOSH CONNECT ") else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4 else { continue }
            let port = String(parts[2]), key = String(parts[3])
            guard isPort(port), isKey(key) else { continue }
            return MoshConnect(port: port, key: key, pid: parsePID(serverOutput))
        }
        return nil
    }

    /// Pull the detached PID out of `[mosh-server detached, pid = 1234]`. Kept
    /// separate (and lenient about spacing) so a future/older server that words
    /// the line differently just yields nil rather than failing the connect.
    public static func parsePID(_ serverOutput: String) -> Int32? {
        for raw in serverOutput.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[mosh-server detached"), let eq = line.firstIndex(of: "=") else { continue }
            let digits = line[line.index(after: eq)...]
                .prefix { $0 != "]" }
                .trimmingCharacters(in: .whitespaces)
            if let pid = Int32(digits), pid > 0 { return pid }
        }
        return nil
    }

    private static func isPort(_ s: String) -> Bool {
        guard let n = UInt16(s), n > 0 else { return false }
        return true
    }

    // 22 base64 chars (16 bytes, unpadded), the alphabet mosh emits.
    private static func isKey(_ s: String) -> Bool {
        guard s.count == 22 else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" }
    }
}
