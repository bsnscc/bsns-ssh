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

    public init(port: String, key: String) {
        self.port = port
        self.key = key
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
            return MoshConnect(port: port, key: key)
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
