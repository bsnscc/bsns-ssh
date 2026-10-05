import Foundation
import Observation
import UserNotifications
import AppKit
import BsnsSSHCore

/// Questions and notices from programs on this Mac, waiting for their owner.
///
/// A script runs `bsns ask "Deploy?" --option approve --option rollback`; the
/// question appears here, in the menu bar and as a notification with those
/// answers as buttons, and the script gets the choice back when one is made.
/// The control socket only accepts this user's processes, and all it can do is
/// put a question in front of them — it runs nothing.
@MainActor
@Observable
final class AskCenter {
    static let shared = AskCenter()

    enum Outcome: Sendable { case answered(String), expired, withdrawn }

    private(set) var pending: [Ask] = []
    /// Recent notices and answered questions, newest first.
    private(set) var history: [Entry] = []

    struct Entry: Identifiable {
        let id = UUID()
        let ask: Ask
        let answer: String?
    }

    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Outcome, Never>] = [:]
    @ObservationIgnored private var server: ControlSocketServer?
    @ObservationIgnored private var collector: Task<Void, Never>?
    /// Passes each new question on to the user's other devices, when set.
    @ObservationIgnored var relay: (@MainActor (Ask) -> Void)?
    @ObservationIgnored var relayWithdraw: (@MainActor (Ask) -> Void)?

    static var machineName: String { Host.current().localizedName ?? "This Mac" }

    /// Also send asks to the user's paired phone through their iCloud.
    static let relayKey = "ask.relayThroughICloud"

    /// Apply the setting: start or stop relaying.
    func applyRelaySetting() {
        let on = UserDefaults.standard.bool(forKey: Self.relayKey)
        let publish: @MainActor (Ask) -> Void = { ask in
            _ = Task<Void, Never> { await CloudRelay.shared.publish(ask) }
        }
        let retract: @MainActor (Ask) -> Void = { ask in
            _ = Task<Void, Never> { await CloudRelay.shared.retract(ask) }
        }
        relay = on ? publish : nil
        relayWithdraw = on ? retract : nil
        collector?.cancel()
        collector = nil
        guard on else { return }
        // While something is waiting, look for its answer every few seconds.
        collector = Task { [weak self] in
            while !Task.isCancelled {
                if let self, !self.pending.isEmpty {
                    for answer in await CloudRelay.shared.collectAnswers(for: self.pending) {
                        if let ask = self.pending.first(where: { $0.id == answer.askID }), self.answer(answer) {
                            await CloudRelay.shared.retract(ask)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func start() {
        guard server == nil else { return }
        let server = ControlSocketServer { [weak self] request, isOpen in
            await self?.handle(request, isOpen: isOpen) ?? ["error": "the app is shutting down"]
        }
        do { try server.start(); self.server = server }
        catch { DiagLog.log("ask", "control socket failed: \(error.localizedDescription)") }
        // Take the socket file away on a normal quit, so a script gets a clear
        // "the app isn't running" instead of a dead socket.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    // MARK: asking

    /// Put a question to the user and wait for the outcome.
    func ask(_ ask: Ask) async -> Outcome {
        pending.append(ask)
        announce(ask)
        relay?(ask)
        let lifetime = max(1, ask.expires.timeIntervalSinceNow)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            self?.finish(ask.id, .expired)
        }
        return await withCheckedContinuation { waiters[ask.id] = $0 }
    }

    func notify(_ notice: Ask) {
        history.insert(Entry(ask: notice, answer: nil), at: 0)
        history = Array(history.prefix(50))
        announce(notice)
        relay?(notice)
    }

    /// The user (here, or on another device) chose an answer. Ignored unless it
    /// is one of the options this question offered, in time.
    @discardableResult
    func answer(_ answer: AskAnswer) -> Bool {
        guard let ask = pending.first(where: { $0.id == answer.askID }), ask.accepts(answer) else { return false }
        history.insert(Entry(ask: ask, answer: answer.choice), at: 0)
        history = Array(history.prefix(50))
        finish(ask.id, .answered(answer.choice))
        return true
    }

    /// The asking program went away; nobody is waiting for this any more.
    func withdraw(_ id: UUID) { finish(id, .withdrawn) }

    private func finish(_ id: UUID, _ outcome: Outcome) {
        guard let ask = pending.first(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        if case .answered = outcome {} else { relayWithdraw?(ask) }
        waiters.removeValue(forKey: id)?.resume(returning: outcome)
    }

    // MARK: the control socket

    private func handle(_ request: [String: Any], isOpen: @escaping @Sendable () -> Bool) async -> [String: Any] {
        guard let text = (request["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return ["error": "nothing to say"]
        }
        let source = request["source"] as? String
        switch request["op"] as? String {
        case "notify":
            notify(Ask(text: text, machine: Self.machineName, source: source, lifetime: 24 * 3600))
            return ["ok": true]
        case "ask":
            let options = (request["options"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !options.isEmpty, Set(options).count == options.count else { return ["error": "ask needs distinct options"] }
            guard options.count <= Ask.maxOptions else { return ["error": "at most \(Ask.maxOptions) options"] }
            let lifetime = min(max((request["timeout"] as? Double) ?? 3600, 5), 7 * 24 * 3600)
            let ask = Ask(text: text, options: options, machine: Self.machineName, source: source, lifetime: lifetime)
            // If the asking program is killed, the question goes with it.
            let watcher = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if !isOpen() { self?.withdraw(ask.id); return }
                }
            }
            let outcome = await self.ask(ask)
            watcher.cancel()
            switch outcome {
            case .answered(let choice): return ["choice": choice]
            case .expired: return ["error": "nobody answered in time"]
            case .withdrawn: return ["error": "withdrawn"]
            }
        default:
            return ["error": "unknown request"]
        }
    }

    // MARK: getting the user's attention on this Mac

    private func announce(_ ask: Ask) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = ask.source.map { "\($0) on \(ask.machine)" } ?? ask.machine
        content.body = ask.text
        content.sound = .default
        if ask.isQuestion {
            // One category per distinct set of answers, so each button says
            // what it means.
            let category = "ask:" + ask.options.joined(separator: "\u{1f}")
            let actions = ask.options.map { UNNotificationAction(identifier: $0, title: $0, options: []) }
            center.getNotificationCategories { existing in
                var categories = existing.filter { $0.identifier != category }
                categories.insert(UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: []))
                center.setNotificationCategories(categories)
                content.categoryIdentifier = category
                center.add(UNNotificationRequest(identifier: ask.id.uuidString, content: content, trigger: nil))
            }
        } else {
            center.add(UNNotificationRequest(identifier: ask.id.uuidString, content: content, trigger: nil))
        }
        if !NSApp.isActive { NSApp.requestUserAttention(ask.isQuestion ? .criticalRequest : .informationalRequest) }
    }
}

/// A notification button was pressed: that is the answer.
final class AskNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AskNotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            if let id = UUID(uuidString: identifier), action != UNNotificationDefaultActionIdentifier,
               action != UNNotificationDismissActionIdentifier {
                AskCenter.shared.answer(AskAnswer(askID: id, choice: action))
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            completionHandler()
        }
    }

    /// Show them even while the app is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// `~/.bsns/control.sock`: one JSON object per line in, one per line out. Only
/// this user's processes may connect.
final class ControlSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable ([String: Any], _ isOpen: @escaping @Sendable () -> Bool) async -> [String: Any]

    static var socketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bsns/control.sock")
    }

    private let handler: Handler
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clients: Set<Int32> = []

    init(handler: @escaping Handler) { self.handler = handler }

    func start() throws {
        let url = Self.socketURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        unlink(url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSocketServer.ServerError.system("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard url.path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw AgentSocketServer.ServerError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: url.path.utf8) }
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0 else { let code = errno; close(fd); throw AgentSocketServer.ServerError.system("bind", code) }
        guard listen(fd, 16) == 0 else { let code = errno; close(fd); throw AgentSocketServer.ServerError.system("listen", code) }
        lock.withLock { listenFD = fd }
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        let (fd, open): (Int32, Set<Int32>) = lock.withLock {
            let fd = listenFD
            listenFD = -1
            return (fd, clients)
        }
        for client in open { shutdown(client, SHUT_RDWR) }
        guard fd >= 0 else { return }
        close(fd)
        unlink(Self.socketURL.path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let admitted: Bool = lock.withLock {
                guard listenFD >= 0 else { return false }
                clients.insert(client)
                return true
            }
            guard admitted else { close(client); continue }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    /// One request per connection: read a line, answer it, close. While the
    /// answer is awaited, the client hanging up is noticed and reported.
    private func serve(_ fd: Int32) {
        defer {
            lock.withLock { _ = clients.remove(fd) }
            close(fd)
        }
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !line.contains(0x0a) {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0, line.count < 64 * 1024 else { return }
            line.append(contentsOf: buffer[0..<count])
        }
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }

        let state = ConnectionState()
        let done = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        Task {
            box.value = await handler(request) { state.isOpen }
            done.signal()
        }
        // Until the answer is ready, watch for the other end going away.
        while done.wait(timeout: .now() + .milliseconds(300)) == .timedOut {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 0) > 0 {
                var probe: UInt8 = 0
                let peeked = recv(fd, &probe, 1, MSG_PEEK | MSG_DONTWAIT)
                if peeked == 0 || (descriptor.revents & Int16(POLLHUP)) != 0 { state.close() }
            }
        }
        guard state.isOpen, var out = try? JSONSerialization.data(withJSONObject: box.value) else { return }
        out.append(0x0a)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private final class ResponseBox: @unchecked Sendable { var value: [String: Any] = [:] }

    private final class ConnectionState: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true
        var isOpen: Bool { lock.withLock { open } }
        func close() { lock.withLock { open = false } }
    }
}
