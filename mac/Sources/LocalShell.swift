import Foundation
import SwiftTerm
import BsnsSSHCore

/// A login shell on this Mac, as a session transport — so a local terminal is
/// one more tab beside the remote ones, with the same view, key handling and
/// scrollback.
final class LocalShell: TerminalTransport, LocalProcessDelegate {
    /// Output that arrives before anyone is listening (the shell starts before
    /// the session is wired to it) is held and handed over, so the first prompt
    /// isn't lost.
    var onOutput: (@Sendable (ArraySlice<UInt8>) -> Void)? {
        get { lock.withLock { output } }
        set {
            let held: [UInt8] = lock.withLock {
                output = newValue
                guard newValue != nil else { return [] }
                defer { pending = [] }
                return pending
            }
            if !held.isEmpty { newValue?(held[...]) }
        }
    }
    private var output: (@Sendable (ArraySlice<UInt8>) -> Void)?
    private var pending: [UInt8] = []
    var onClosed: (@Sendable (String?) -> Void)?
    /// The shell ended by itself with a clean status (`exit`, ^D).
    var onCleanExit: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "cc.bsns.ssh.local-shell")
    private let lock = NSLock()
    private var process: LocalProcess?
    private var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    private var stopped = false

    /// Start the user's login shell in their home directory. `agentSocket` is
    /// the app's agent, when it is being served: ssh and git in this shell then
    /// sign with the keys held here.
    func start(cols: Int32, rows: Int32, agentSocket: String?) {
        lock.withLock { size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0) }
        let shell = Self.loginShell()
        let inherited = ProcessInfo.processInfo.environment
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        // The login shell builds the rest (PATH included) from the user's own
        // profile; this is only what it can't know by itself.
        environment.append("PATH=/usr/bin:/bin:/usr/sbin:/sbin")
        environment.append("SHELL=\(shell)")
        environment.append("TERM_PROGRAM=bsns.SSH")
        if let tmp = inherited["TMPDIR"] { environment.append("TMPDIR=\(tmp)") }
        if let socket = agentSocket ?? inherited["SSH_AUTH_SOCK"] { environment.append("SSH_AUTH_SOCK=\(socket)") }

        let process = LocalProcess(delegate: self, dispatchQueue: queue)
        lock.withLock { self.process = process }
        // A leading dash in argv[0] is what makes it a login shell.
        process.startProcess(executable: shell, args: [], environment: environment,
                             execName: "-" + (shell as NSString).lastPathComponent,
                             currentDirectory: NSHomeDirectory())
    }

    /// The shell set for this account, falling back to zsh.
    static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    // MARK: TerminalTransport

    func write(_ bytes: ArraySlice<UInt8>) {
        lock.withLock { process }?.send(data: bytes)
    }

    func resize(cols: Int32, rows: Int32) {
        let (process, fresh): (LocalProcess?, winsize) = lock.withLock {
            size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
            return (self.process, size)
        }
        guard let process, process.running, process.childfd >= 0 else { return }
        var window = fresh
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &window)
    }

    func disconnect() {
        let process: LocalProcess? = lock.withLock {
            stopped = true
            return self.process
        }
        guard let process, process.running else { return }
        // What a closed terminal window sends: an interactive shell ignores
        // SIGTERM, but hangs up — and takes its jobs with it.
        if process.shellPid > 0 { kill(process.shellPid, SIGHUP) }
        process.terminate()
    }

    // MARK: LocalProcessDelegate

    func dataReceived(slice: ArraySlice<UInt8>) {
        let deliver: (@Sendable (ArraySlice<UInt8>) -> Void)? = lock.withLock {
            if output == nil { pending.append(contentsOf: slice) }
            return output
        }
        deliver?(slice)
    }

    func getWindowSize() -> winsize { lock.withLock { size } }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        if lock.withLock({ stopped }) { return }
        if exitCode == 0 {
            onCleanExit?()
            onClosed?(nil)
        } else {
            onClosed?(exitCode.map { "The shell exited with status \($0)." } ?? "The shell ended.")
        }
    }
}

@MainActor
enum LocalShellLauncher {
    /// Open a new local shell tab.
    @discardableResult
    static func open(sessions: SessionStore, surfaces: MacSurfaceCache, store: AgentStore) -> TerminalSession {
        let name = (LocalShell.loginShell() as NSString).lastPathComponent
        let count = sessions.sessions.filter(\.isLocal).count
        let spec = TerminalSession.Spec(host: "localhost", port: 0, user: NSUserName(),
                                        agent: store.agent, knownHosts: KnownHosts())
        let session = TerminalSession(spec: spec, title: count == 0 ? "This Mac · \(name)" : "This Mac · \(name) (\(count + 1))")
        let id = session.id
        session.relaunchLocal = { [weak sessions, weak surfaces] cols, rows in
            let shell = LocalShell()
            // `exit` closes the tab, as it does in any terminal.
            shell.onCleanExit = {
                Task { @MainActor in
                    guard let sessions, let closing = sessions.sessions.first(where: { $0.id == id }) else { return }
                    surfaces?.drop(id)
                    sessions.close(closing)
                }
            }
            // The socket file is there exactly while the agent is being served.
            let socket = AgentSocketServer.socketURL.path
            shell.start(cols: cols, rows: rows,
                        agentSocket: FileManager.default.fileExists(atPath: socket) ? socket : nil)
            return shell
        }
        sessions.add(session)
        session.start()
        return session
    }
}
