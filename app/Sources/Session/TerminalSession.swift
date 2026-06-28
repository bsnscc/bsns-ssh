import Foundation
import Observation
import BsnsSSHCore

/// Owns the live `SSHShell` for one terminal and survives it: tracks connection
/// status, forwards I/O, and can rebuild the shell from a stored spec for
/// one-tap reconnect. The terminal view talks to the session, not the shell, so
/// a reconnect swaps the underlying shell without the view knowing.
@Observable
final class TerminalSession: Identifiable, @unchecked Sendable {
    let id: UUID

    enum Status: Equatable {
        case connecting
        case connected
        case disconnected(reason: String?)   // nil = clean / user-initiated
    }

    /// Everything needed to re-establish the connection.
    struct Spec {
        let host: String
        let port: UInt16
        let user: String
        let agent: Agent
        var knownHosts: KnownHosts
        var useMosh: Bool = false
        var jump: SSHShell.JumpHop? = nil
        /// The chosen key's public-key blob — auth offers only this identity (so a
        /// reconnect keeps using the same key the user picked). nil = offer all.
        var keyBlob: Data? = nil
        /// Optional tmux session name (mosh): the bootstrap launches
        /// `tmux new-session -A -s <name>` so reconnects re-attach the same session.
        var tmuxSession: String? = nil
        // Note: no password is retained. Reconnect uses the agent (keys); a
        // password-only session must be re-established from the Connect screen.
    }

    private(set) var status: Status = .connecting
    /// mosh-only: the server has gone silent past the liveness threshold. The
    /// status stays `.connected` (mosh may still recover by roaming), but the UI
    /// surfaces staleness so a dead session isn't shown as a reassuring green.
    private(set) var isStale = false
    /// Transient status for an in-flight image drop/paste upload (nil = hidden).
    /// The terminal screen shows it as a small overlay banner. Always mutated on
    /// the main queue (it drives UI), same discipline as `status` / `isStale`.
    private(set) var transferStatus: String?
    let spec: Spec
    let title: String

    /// Set by the terminal coordinator; receives shell output (called off-main —
    /// the coordinator hops to main itself, matching SSHShell's existing contract).
    ///
    /// Output produced before the surface attaches is buffered and flushed the
    /// moment this is set. This matters for mosh: its bootstrap runs the whole SSH
    /// exchange before `open()`, so the server has already painted and the first
    /// full-repaint frame arrives almost immediately — before the lazily-created
    /// surface wires this up. Delivered to a nil closure it would be dropped, after
    /// which `mosh_client_drain_ansi` only emits diffs and an idle shell never
    /// repaints, leaving a blank screen. (SSH is slower to first byte and dodges
    /// the race, but buffering makes both transports correct.)
    var onOutput: (@Sendable (ArraySlice<UInt8>) -> Void)? {
        didSet {
            lock.lock()
            guard onOutput != nil, !outputBuffer.isEmpty else { lock.unlock(); return }
            let buffered = outputBuffer
            outputBuffer.removeAll(keepingCapacity: false)
            let out = onOutput
            lock.unlock()
            out?(buffered[...])
        }
    }
    private var outputBuffer: [UInt8] = []

    private let lock = NSLock()
    /// A configured local (-L) forward. Survives reconnect (re-applied to the
    /// new shell). `error` is non-nil if the local bind failed.
    struct Forward: Identifiable, Equatable {
        let id: UUID
        let listenPort: UInt16
        let destHost: String
        let destPort: UInt16
        var error: String?
    }
    private(set) var forwards: [Forward] = []

    private var transport: TerminalTransport?
    private var cols: Int32 = 80
    private var rows: Int32 = 24

    /// Mosh has no in-session forwarding, so forwards only apply to an SSH shell.
    private var sshShell: SSHShell? { currentTransport as? SSHShell }

    /// A snapshot sufficient to re-create and reconnect this session after the app
    /// is killed — set by the creator for sessions that should survive a relaunch
    /// (mosh / direct SSH; nil for jump sessions, which aren't auto-restored). The
    /// session store persists it on add and forgets it on close.
    var restorable: RestorableSession?

    init(id: UUID = UUID(), spec: Spec, title: String) {
        self.id = id
        self.spec = spec
        self.title = title
    }

    /// Connect a freshly-created session (e.g. one restored at launch) from its
    /// spec — same path as a reconnect, so mosh re-bootstraps (re-attaching its
    /// tmux session) and SSH rebuilds its shell.
    func start() { performReconnect(reason: "launch restore") }

    /// Add a local forward and start it on the current shell. Returns nil on
    /// success or an error string (e.g. the local port is in use).
    @discardableResult
    func addForward(listenPort: UInt16, destHost: String, destPort: UInt16) -> String? {
        // Forwarding is multiplexed over the SSH channel — mosh (UDP) has none.
        guard let shell = sshShell else { return "Port forwarding isn't available over mosh." }
        let id = UUID()
        let err = shell.addLocalForward(id: id, bindAddress: "127.0.0.1",
                                        listenPort: listenPort, destHost: destHost, destPort: destPort)
        forwards.append(Forward(id: id, listenPort: listenPort, destHost: destHost, destPort: destPort, error: err))
        return err
    }

    func removeForward(_ id: UUID) {
        sshShell?.removeLocalForward(id: id)
        forwards.removeAll { $0.id == id }
    }

    /// Re-establish all configured forwards on the current shell (after reconnect).
    private func reapplyForwards() {
        guard let shell = sshShell else { return }
        for i in forwards.indices {
            let f = forwards[i]
            forwards[i].error = shell.addLocalForward(id: f.id, bindAddress: "127.0.0.1",
                                                      listenPort: f.listenPort, destHost: f.destHost, destPort: f.destPort)
        }
    }

    /// Adopt an already-connected transport — the initial connect (and its TOFU
    /// prompt) is handled by ConnectView before the terminal appears.
    func adopt(_ transport: TerminalTransport) {
        wire(transport)
        lock.lock(); self.transport = transport; lock.unlock()
        DispatchQueue.main.async { self.isStale = false }
        setStatus(.connected)
    }

    func write(_ bytes: ArraySlice<UInt8>) {
        trackInput(bytes)
        currentTransport?.write(bytes)
    }

    /// Send a snippet / history command into the session, with a trailing newline
    /// so the last line executes. Multi-line commands run as a sequence.
    func runCommand(_ command: String) {
        guard case .connected = status else { return }
        let text = command.hasSuffix("\n") ? command : command + "\n"
        write(Array(text.utf8)[...])
    }

    /// Upload an image dropped or pasted onto the terminal to the configured
    /// remote drop directory (over a fresh SFTP connection built from this
    /// session's spec — so it works even when the live session is mosh, which has
    /// no file channel), then inject the absolute remote path at the cursor so the
    /// user can reference it in a prompt. Status surfaces via `transferStatus`.
    func uploadImage(_ data: Data, ext: String) {
        let spec = self.spec
        setTransfer("Uploading image…")
        Task { @Sendable in
            let client = SFTPClient()
            do {
                try await client.connect(host: spec.host, port: spec.port, user: spec.user,
                                         agent: spec.agent, knownHosts: spec.knownHosts, keyBlob: spec.keyBlob)

                // Resolve the drop dir. Absolute stays as-is; "~"-relative expands
                // against the SFTP session's home (realpath of "."); anything else is
                // treated as relative to home too.
                let configured = (UserDefaults.standard.string(forKey: SettingsKey.uploadDir) ?? "~/.bsns-ssh-drops")
                    .trimmingCharacters(in: .whitespaces)
                let raw = configured.isEmpty ? "~/.bsns-ssh-drops" : configured
                let dir: String
                if raw.hasPrefix("/") {
                    dir = raw
                } else {
                    let home = try await client.realpath(".")
                    let rel = raw.hasPrefix("~") ? String(raw.dropFirst()).drop(while: { $0 == "/" }) : raw[...]
                    dir = rel.isEmpty ? home : home + "/" + rel
                }
                try await client.mkdir(dir)

                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "yyyyMMdd-HHmmss"
                let stamp = fmt.string(from: Date())
                let suffix = String(UInt32.random(in: 0..<0x10000), radix: 16)
                let safeExt = ext.isEmpty ? "png" : ext
                let name = "shot-\(stamp)-\(suffix).\(safeExt)"
                let path = dir + "/" + name

                try await client.upload(data, to: path)
                client.disconnect()

                await MainActor.run {
                    self.write(Array((path + " ").utf8)[...])
                    self.setTransfer("Uploaded → \(name)")
                }
            } catch {
                client.disconnect()
                self.setTransfer("Upload failed: \(Self.describe(error))")
            }
        }
    }

    /// Set the transient transfer banner and auto-clear it after ~4s (the clear
    /// only fires if no newer status replaced it in the meantime).
    private func setTransfer(_ text: String?) {
        DispatchQueue.main.async {
            self.transferStatus = text
            guard text != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if self.transferStatus == text { self.transferStatus = nil }
            }
        }
    }

    // Local command history: watch the keystroke byte-stream, accumulate a line
    // buffer, and record it on Enter. Best-effort (skips escape sequences); feeds
    // the on-device history only, never leaves the device.
    private var lineBuf = ""
    private var inEscape = false
    /// Armed when recent OUTPUT looks like a password / passphrase prompt. The
    /// next submitted line is then NOT recorded — at such a prompt the remote
    /// reads with echo OFF, but the keystrokes still flow through this tap, so
    /// without this guard a typed password would land in history.
    private var awaitingSecret = false
    /// Rolling tail of recent printable output, for prompt detection across chunks.
    private var outTail = ""

    /// Output-side cues (lowercased) that a secret is being prompted for. Liberal
    /// on purpose: a false positive only drops one command from history, while a
    /// miss would record a password — so we bias hard toward suppression.
    private static let secretPromptCues = [
        "password:", "password for", "'s password", "passphrase",
        "[sudo] password", "verification code", "one-time password",
        "enter pin", "pin:", "otp",
    ]

    /// Inspect transport output (lock held) and arm secret-suppression when a
    /// password/passphrase prompt appears.
    private func noteOutputForSecretPrompt(_ bytes: ArraySlice<UInt8>) {
        for b in bytes where (0x20...0x7e).contains(b) || b == 0x0a {
            outTail.append(Character(UnicodeScalar(b)))
        }
        if outTail.count > 256 { outTail = String(outTail.suffix(256)) }
        let hay = outTail.lowercased()
        if Self.secretPromptCues.contains(where: { hay.contains($0) }) {
            awaitingSecret = true
            outTail = ""   // consume so we don't re-arm on the same stale text
        }
    }

    private func trackInput(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        for b in bytes {
            switch b {
            case _ where inEscape: if (0x40...0x7e).contains(b) { inEscape = false }
            case 0x1b: inEscape = true
            case 0x0d, 0x0a:
                let raw = lineBuf
                lineBuf = ""
                // A line submitted right after a password prompt is a secret — never
                // record it (and disarm; one wrong-password retry re-arms on the
                // next prompt).
                let secret = awaitingSecret
                awaitingSecret = false
                // Honor the shell `ignorespace` convention + the user's history
                // toggle: a line typed with a leading space is never recorded
                // (use it for secrets), and history can be turned off entirely.
                let line = raw.trimmingCharacters(in: .whitespaces)
                if !secret, !line.isEmpty, !raw.hasPrefix(" "),
                   UserDefaults.standard.bool(forKey: SettingsKey.commandHistory) {
                    CommandHistory.shared.record(line)
                }
            case 0x03, 0x15: lineBuf = ""                          // Ctrl-C / Ctrl-U
            case 0x7f, 0x08: if !lineBuf.isEmpty { lineBuf.removeLast() }
            case 0x20...0x7e: lineBuf.append(Character(UnicodeScalar(b)))
            default: break
            }
        }
        lock.unlock()
    }

    func resize(cols: Int32, rows: Int32) {
        lock.lock(); self.cols = cols; self.rows = rows; let t = transport; lock.unlock()
        t?.resize(cols: cols, rows: rows)
    }

    func refreshDisplay() { currentTransport?.requestDisplayRefresh() }

    func disconnect() { currentTransport?.disconnect() }

    var isDisconnected: Bool { if case .disconnected = status { return true } else { return false } }

    /// Rebuild the transport and reconnect with the stored spec + last known size.
    /// SSH rebuilds the shell directly; mosh re-runs the SSH bootstrap (a fresh
    /// `mosh-server`), since a hard drop means the old UDP session is gone.
    func reconnect() {
        guard isDisconnected else { return }
        performReconnect(reason: nil)
    }

    /// Shared connect/reconnect path. `start()` uses it for restored sessions;
    /// `reconnect()` uses it after an explicit disconnect. The old transport is
    /// torn down with its callbacks detached first, so its teardown can't flip
    /// status back to disconnected and race the new connection.
    private func performReconnect(reason: String?) {
        if let old = currentTransport {
            old.onOutput = nil
            old.onClosed = nil
            old.disconnect()
        }
        DispatchQueue.main.async { self.isStale = false }
        setStatus(.connecting)
        lock.lock(); let cols = self.cols, rows = self.rows; lock.unlock()
        let spec = self.spec
        Task {
            do {
                if spec.useMosh {
                    let connect = try await MoshBootstrap.connect(spec: spec)
                    let mosh = MoshSession()
                    self.wire(mosh)
                    if let err = mosh.open(host: spec.host, port: connect.port, key: connect.key, cols: cols, rows: rows) {
                        throw MoshBootstrap.Failure.noConnectLine(err)
                    }
                    self.lock.withLock { self.transport = mosh }
                } else {
                    let shell = SSHShell()
                    self.wire(shell)
                    self.lock.withLock { self.transport = shell }
                    try await shell.connect(host: spec.host, port: spec.port, user: spec.user,
                                            agent: spec.agent, cols: cols, rows: rows,
                                            knownHosts: spec.knownHosts, password: nil, jump: spec.jump,
                                            keyBlob: spec.keyBlob)
                    DispatchQueue.main.async { self.reapplyForwards() }
                }
                self.setStatus(.connected)
            } catch {
                self.setStatus(.disconnected(reason: Self.describe(error)))
            }
        }
    }

    // MARK: internals

    private var currentTransport: TerminalTransport? { lock.lock(); defer { lock.unlock() }; return transport }

    private func wire(_ transport: TerminalTransport) {
        transport.onOutput = { [weak self] bytes in self?.deliver(bytes) }
        transport.onClosed = { [weak self] reason in
            self?.setStatus(.disconnected(reason: reason))
        }
        if let mosh = transport as? MoshSession {
            mosh.onLiveness = { [weak self] stale in
                DispatchQueue.main.async { self?.isStale = stale }
            }
        }
    }

    /// Forward transport output to the surface, or buffer it until the surface
    /// attaches and `onOutput` is set (see that property's note).
    private func deliver(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        noteOutputForSecretPrompt(bytes)
        if onOutput == nil {
            outputBuffer.append(contentsOf: bytes)
            lock.unlock()
            return
        }
        let out = onOutput
        lock.unlock()
        out?(bytes)
    }

    private func setStatus(_ s: Status) {
        DispatchQueue.main.async { self.status = s }
    }

    /// The single place that turns an error into user-facing text — used by both
    /// the reconnect banner and the Connect screen so messages stay consistent
    /// and never leak a raw `Error` description.
    static func describe(_ error: Error) -> String {
        switch error {
        case SSHShellError.connectFailed:
            return "Couldn't reach the server. Check the host, port, and your network."
        case SSHShellError.handshakeFailed:
            return "SSH handshake failed — the server may not speak SSH, or uses unsupported algorithms."
        case SSHShellError.authFailed(let m):
            return "Authentication failed: \(m)"
        case SSHShellError.hostKeyMismatch:
            return "⚠️ The host key changed — possible interception. Connection refused."
        case SSHShellError.unknownHostKey:
            return "The server's host key isn't trusted yet."
        case SSHShellError.unknownJumpHostKey:
            return "The jump host's key isn't trusted yet — connect from the Connect screen to verify it."
        case SSHShellError.jumpHostKeyMismatch:
            return "⚠️ The jump host's key changed — possible interception. Connection refused."
        case SSHShellError.noIdentities:
            return "No key available — add or generate a key first."
        case SSHShellError.noHostKey:
            return "The server didn't present a host key."
        case SSHShellError.channelOpenFailed, SSHShellError.ptyFailed, SSHShellError.shellFailed:
            return "Couldn't open a session on the server."
        case SSHShellError.execFailed(let m):
            return "Couldn't run the command on the server: \(m)"
        case SSHShellError.libssh2Init, SSHShellError.sessionInit:
            return "Couldn't start the SSH session."
        case SSHShellError.algorithmPolicyFailed:
            return "Couldn't enforce the secure algorithm policy — connection refused."
        case let e as LocalizedError where e.errorDescription != nil:
            return e.errorDescription!
        default:
            return "Something went wrong. Please try again."
        }
    }
}
