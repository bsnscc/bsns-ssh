import Foundation

/// Small, pure text decisions the terminal UI makes — kept here so they can be
/// unit-tested without a device.

/// Whether a paste should be confirmed before it is sent.
public enum PasteGuard {
    /// When to ask.
    public enum Policy: String, CaseIterable, Sendable {
        case never
        /// Only when the terminal can see that each line would run on arrival.
        case whenRisky
        /// Every multi-line paste.
        case always
    }

    /// A paste is risky when it holds more than one line AND the program on the
    /// other end hasn't asked for bracketed paste: each line break then arrives
    /// as Enter, so a pasted block runs line by line the moment it lands. With
    /// bracketed paste on, the program receives the block as one unit and
    /// decides for itself (shells wait for Enter; editors insert it), so there
    /// is nothing to confirm. A single trailing newline doesn't make a paste
    /// multi-line — copying a whole line often includes one.
    ///
    /// `whenRisky` can only judge what the terminal sees. A multiplexer always
    /// asks the terminal for bracketed paste on its own behalf and then hands
    /// the paste to the program inside in whatever form *that* program wants —
    /// so inside one, the terminal can't tell a safe paste from a risky one, and
    /// `whenRisky` never fires. `always` is the policy that covers that case.
    public static func needsConfirmation(_ text: String, bracketedPaste: Bool,
                                         policy: Policy = .whenRisky) -> Bool {
        switch policy {
        case .never: return false
        case .whenRisky: return !bracketedPaste && lineCount(text) > 1
        case .always: return lineCount(text) > 1
        }
    }

    /// Lines in the paste, ignoring one trailing line break.
    public static func lineCount(_ text: String) -> Int {
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        if body.hasSuffix("\n") || body.hasSuffix("\r") { body.removeLast() }
        guard !body.isEmpty else { return 0 }
        return body.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }).count
    }

    /// The first few lines, shortened, for the confirmation prompt.
    public static func preview(_ text: String, maxLines: Int = 4, maxWidth: Int = 60) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
        var shown = lines.prefix(maxLines).map { line -> String in
            line.count > maxWidth ? String(line.prefix(maxWidth)) + "…" : String(line)
        }
        if lines.count > maxLines { shown.append("…") }
        return shown.joined(separator: "\n")
    }
}

/// A URL printed by a program on the server that points at the server's own
/// loopback — a dev server announcing `http://localhost:3000`. Opening it on
/// this device as-is would reach the device's loopback, not the server's; it
/// needs a forwarded port.
public struct LoopbackURL: Equatable, Sendable {
    /// Where the server-side end of the forward should connect.
    public let remoteHost: String
    public let remotePort: UInt16
    public let scheme: String
    /// Path, query and fragment, to re-attach once the port is forwarded.
    public let suffix: String

    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return nil }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch bare {
        // `0.0.0.0` is "every interface" on the server; loopback is one of them.
        case "localhost", "0.0.0.0": remoteHost = "localhost"
        case "::1": remoteHost = "::1"
        default:
            guard bare.hasPrefix("127."), bare.split(separator: ".").count == 4 else { return nil }
            remoteHost = bare
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard let remotePort = UInt16(exactly: port), remotePort > 0 else { return nil }
        self.remotePort = remotePort
        self.scheme = scheme

        var suffix = url.path
        if let query = url.query { suffix += "?" + query }
        if let fragment = url.fragment { suffix += "#" + fragment }
        self.suffix = suffix
    }

    /// Local ports to try listening on, best first: the same number the server
    /// uses (so the address bar matches what the program printed), then the
    /// next few in case it's taken. Privileged ports can't be bound on a phone,
    /// so those are mapped up into the 8000s.
    public var localPortCandidates: [UInt16] {
        let base: UInt32 = remotePort >= 1024 ? UInt32(remotePort) : 8000 + UInt32(remotePort)
        return (0..<10).compactMap { UInt16(exactly: base + $0) }
    }

    /// The address to open on this device once `localPort` forwards to the server.
    public func localURL(port localPort: UInt16) -> URL? {
        URL(string: "\(scheme)://127.0.0.1:\(localPort)\(suffix)")
    }
}

/// Finds shell prompts in captured terminal text by pattern, for output that
/// carries no prompt markers of its own (a multiplexer's history, which keeps
/// the text but not the marks).
public struct PromptScan: Sendable {
    /// Matches the common `user@host … $` shapes: zsh's and bash's defaults, and
    /// `#` for root. Anchored at the line start so command output that merely
    /// mentions an address isn't taken for a prompt.
    public static let defaultPattern = #"^\S+@\S+[ :].*?[%$#>](\s|$)"#

    private let regex: NSRegularExpression

    /// Nil when `pattern` isn't a valid regular expression.
    public init?(pattern: String) {
        guard !pattern.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        self.regex = regex
    }

    public func isPrompt(_ line: Substring) -> Bool {
        let s = String(line)
        return regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Indices of the lines that look like prompts.
    public func promptLines(in lines: [Substring]) -> [Int] {
        lines.indices.filter { isPrompt(lines[$0]) }
    }

    /// The last row of the command typed at the prompt on line `prompt`. A
    /// command longer than the screen continues on the following rows, each
    /// earlier one filled to the full `width`; without a width, one row.
    func commandEnd(ofPromptAt prompt: Int, in lines: [Substring], width: Int?) -> Int {
        guard let width, width > 0 else { return prompt }
        var row = prompt
        while row + 1 < lines.count, lines[row].count >= width, !isPrompt(lines[row + 1]) { row += 1 }
        return row
    }

    /// The output of the most recent command that printed anything: the lines
    /// between the last two prompts that have something between them, after the
    /// command itself. The final prompt (the one waiting for input) only closes
    /// the range. `width` is the terminal width the text was captured at.
    public func lastOutput(in lines: [Substring], width: Int? = nil) -> ClosedRange<Int>? {
        let prompts = promptLines(in: lines)
        guard prompts.count >= 2 else { return nil }
        for i in stride(from: prompts.count - 1, to: 0, by: -1) {
            let first = commandEnd(ofPromptAt: prompts[i - 1], in: lines, width: width) + 1
            let last = prompts[i] - 1
            if first <= last, lines[first...last].contains(where: { !$0.allSatisfy(\.isWhitespace) }) {
                return first...last
            }
        }
        return nil
    }
}
