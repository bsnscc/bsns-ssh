import Foundation
import AppKit
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
    private var pendingSpawn: (agentSocket: String?, directory: String?)?

    /// Start the user's login shell in `directory` (their home when nil).
    /// `agentSocket` is the app's agent, when it is being served: ssh and git
    /// in this shell then sign with the keys held here.
    ///
    /// The process isn't spawned here but at the first size the terminal view
    /// reports (or shortly after, if none comes): a shell started at a guessed
    /// size draws its first prompt for the wrong width, which leaves debris on
    /// the first line once the real size arrives.
    func start(cols: Int32, rows: Int32, agentSocket: String?, directory: String? = nil) {
        lock.withLock {
            size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
            pendingSpawn = (agentSocket, directory)
        }
        queue.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.spawnIfPending() }
    }

    private func spawnIfPending() {
        let config: (agentSocket: String?, directory: String?)? = lock.withLock {
            defer { pendingSpawn = nil }
            return stopped ? nil : pendingSpawn
        }
        guard let config else { return }
        let shell = Self.loginShell()
        let inherited = ProcessInfo.processInfo.environment
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        // The login shell builds the rest (PATH included) from the user's own
        // profile; this is only what it can't know by itself.
        environment.append("PATH=/usr/bin:/bin:/usr/sbin:/sbin")
        environment.append("SHELL=\(shell)")
        environment.append("TERM_PROGRAM=bsns.SSH")
        if let tmp = inherited["TMPDIR"] { environment.append("TMPDIR=\(tmp)") }
        if let socket = config.agentSocket ?? inherited["SSH_AUTH_SOCK"] { environment.append("SSH_AUTH_SOCK=\(socket)") }

        var start = NSHomeDirectory()
        var isDirectory: ObjCBool = false
        if let wanted = config.directory, FileManager.default.fileExists(atPath: wanted, isDirectory: &isDirectory),
           isDirectory.boolValue { start = wanted }

        let process = LocalProcess(delegate: self, dispatchQueue: queue)
        lock.withLock { self.process = process }
        // A leading dash in argv[0] is what makes it a login shell.
        process.startProcess(executable: shell, args: [], environment: environment,
                             execName: "-" + (shell as NSString).lastPathComponent,
                             currentDirectory: start)
    }

    /// The shell's working directory right now, if it is running.
    func currentDirectory() -> String? {
        guard let pid = lock.withLock({ process?.shellPid }), pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// The program in the foreground of this terminal when it isn't the shell
    /// itself — "vim", "ssh" — or nil at a prompt.
    func foregroundProgram() -> String? {
        guard let process = lock.withLock({ self.process }), process.running, process.childfd >= 0 else { return nil }
        let group = tcgetpgrp(process.childfd)
        guard group > 0, group != process.shellPid else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(group, &name, UInt32(name.count)) > 0 else { return nil }
        return String(cString: name)
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
        guard let process else {
            // The first real size: this is the moment to start the shell.
            queue.async { [weak self] in self?.spawnIfPending() }
            return
        }
        guard process.running, process.childfd >= 0 else { return }
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
    /// The running shell behind each local session, for its title and for
    /// opening the next tab where this one is.
    private static var shells: [UUID: LocalShell] = [:]

    static func shell(of session: TerminalSession) -> LocalShell? { shells[session.id] }

    /// Open a new local shell tab — in the directory of the local tab being
    /// looked at, if there is one, as a new terminal tab usually does.
    @discardableResult
    static func open(sessions: SessionStore, surfaces: MacSurfaceCache, store: AgentStore) -> TerminalSession {
        let name = (LocalShell.loginShell() as NSString).lastPathComponent
        let directory = sessions.active.flatMap { shells[$0.id]?.currentDirectory() }
        let spec = TerminalSession.Spec(host: "localhost", port: 0, user: NSUserName(),
                                        agent: store.agent, knownHosts: KnownHosts())
        let session = TerminalSession(spec: spec, title: name)
        let id = session.id
        session.relaunchLocal = { [weak sessions, weak surfaces] cols, rows in
            let shell = LocalShell()
            // `exit` closes the tab, as it does in any terminal.
            shell.onCleanExit = {
                Task { @MainActor in
                    shells[id] = nil
                    guard let sessions, let closing = sessions.sessions.first(where: { $0.id == id }) else { return }
                    surfaces?.drop(id)
                    sessions.close(closing)
                }
            }
            // The socket file is there exactly while the agent is being served.
            let socket = AgentSocketServer.socketURL.path
            shell.start(cols: cols, rows: rows,
                        agentSocket: FileManager.default.fileExists(atPath: socket) ? socket : nil,
                        directory: directory)
            Task { @MainActor in shells[id] = shell }
            return shell
        }
        sessions.add(session)
        session.start()
        keepTitleCurrent(session, shellName: name, sessions: sessions)
        return session
    }

    /// "~/work/site" at a prompt, "~/work/site — vim" while something runs.
    private static func keepTitleCurrent(_ session: TerminalSession, shellName: String, sessions: SessionStore) {
        Task { @MainActor [weak session, weak sessions] in
            while let session, let sessions, sessions.sessions.contains(where: { $0.id == session.id }) {
                if let shell = shells[session.id] {
                    var title = shell.currentDirectory().map(abbreviated) ?? shellName
                    if let program = shell.foregroundProgram() { title += " — \(program)" }
                    if session.title != title { session.title = title }
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
            if let session { shells[session.id] = nil }
        }
    }

    private static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Close a tab. A local shell with something still running in it asks first.
    static func close(_ session: TerminalSession, sessions: SessionStore, surfaces: MacSurfaceCache) {
        if let program = shells[session.id]?.foregroundProgram() {
            let alert = NSAlert()
            alert.messageText = "Close this tab?"
            alert.informativeText = "\(program) is still running in it and will be stopped."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        shells[session.id] = nil
        surfaces.drop(session.id)
        sessions.close(session)
    }
}
