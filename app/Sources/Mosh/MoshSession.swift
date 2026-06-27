import Foundation
import UIKit
import CMosh

/// Diagnostics for the mosh resume/size path — view in-app under
/// Settings → Diagnostics (and mirrored to the unified log at `.notice`,
/// subsystem cc.bsns.ssh) while reproducing a background→foreground cycle.
private func moshLog(_ message: String) { DiagLog.log("mosh", message) }

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
    var onOutput: (@Sendable (ArraySlice<UInt8>) -> Void)? {
        get { lock.withLock { onOutputHandler } }
        set { lock.withLock { onOutputHandler = newValue } }
    }
    var onClosed: (@Sendable (String?) -> Void)? {
        get { lock.withLock { onClosedHandler } }
        set { lock.withLock { onClosedHandler = newValue } }
    }
    /// Reports liveness transitions: `true` when the server has gone silent past
    /// the threshold (so the UI can show the session is stale rather than a
    /// reassuring green), `false` when contact resumes. mosh deliberately never
    /// self-closes on silence (it's built to roam), so this is the only signal a
    /// dead session gives us.
    var onLiveness: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { onLivenessHandler } }
        set { lock.withLock { onLivenessHandler = newValue } }
    }
    /// Fires once when a resume's roam fails to re-establish: the remote terminal
    /// state stays frozen despite the user typing into it. The owner falls back to
    /// a full re-bootstrap of a fresh mosh-server (which re-attaches to the same
    /// server-side session) rather than leaving the screen stuck forever.
    var onRoamFailed: (@Sendable () -> Void)? {
        get { lock.withLock { onRoamFailedHandler } }
        set { lock.withLock { onRoamFailedHandler = newValue } }
    }
    private static let staleThreshold: TimeInterval = 8
    private static let postResumeInputRecoveryWindow: TimeInterval = 120
    private static let inputRecoveryDelay: TimeInterval = 0.9
    private static let inputRecoveryCooldown: TimeInterval = 3.0
    // Active recovery while the server is silent and no input is pending (mosh
    // stops resending unacked state ~10s after it last heard from the server).
    private static let staleRecoveryPrimeInterval: TimeInterval = 1.0
    private static let staleRecoveryHopInterval: TimeInterval = 4.0
    private static let staleRecoveryPollCeilingMs: Int32 = 250
    private static let maxRecvDrainPerWake = 64
    // After a resume, if the remote state stays frozen this long while the user is
    // typing into it (send works, receive of state doesn't — a wedged roam), give
    // up on roaming and re-bootstrap a fresh mosh-server.
    private static let roamFailTimeout: TimeInterval = 5.0

    private let queue = DispatchQueue(label: "cc.bsns.ssh.mosh")
    private var onOutputHandler: (@Sendable (ArraySlice<UInt8>) -> Void)?
    private var onClosedHandler: (@Sendable (String?) -> Void)?
    private var onLivenessHandler: (@Sendable (Bool) -> Void)?
    private var onRoamFailedHandler: (@Sendable () -> Void)?
    private var client: OpaquePointer?
    private var lastContactAt = Date()
    private var staleReported = false
    private var lastFbCols: Int32 = 0
    private var lastFbRows: Int32 = 0
    private var lastReportedClientError = ""
    private var inputPushSeq = 0
    private var ansiDrainSeq = 0
    private var awaitingOutputForInputSeq: Int?
    private var awaitingOutputSince: Date?
    private var lastAwaitingOutputLogAt: Date?
    private var lastResumeAt: Date?
    private var lastInputRecoveryAt: Date?
    private var lastStaleRecoveryPrimeAt: Date?
    private var lastStaleRecoveryHopAt: Date?
    // Roam-failure watch, armed on each resume (see roamFailTimeout).
    private var resumeStateNum: UInt64 = 0
    private var resumeInputPushSeq = 0
    private var roamWatchActive = false
    private var roamReconnectFired = false
    private var datagramsSinceResume = 0
    private var validRecvSinceResume = 0

    // Connection params, kept so we can re-create the client socket after iOS
    // suspends us in the background (the mosh-server keeps running, so a fresh
    // socket with the same port+key resumes the session — mosh roaming).
    private var serverIP = ""
    private var serverPort = ""
    private var serverKey = ""
    private var cols: Int32 = 80
    private var rows: Int32 = 24
    private var foregroundObservers: [NSObjectProtocol] = []

    private let lock = NSLock()
    private var pendingInput: [UInt8] = []
    private var pendingResize: (Int32, Int32)?
    private var resumeRequested = false
    private var appInForeground = true
    private var appIsActive = true
    private var pendingForegroundRecovery = false
    private var lastResumeRequestAt: TimeInterval = 0
    private var stopRequested = false
    private var closeNotified = false

    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1

    func open(host: String, port: String, key: String, cols: Int32, rows: Int32) -> String? {
        guard let ip = Self.resolve(host) else { return "couldn't resolve \(host)" }
        let c = mosh_client_create(ip, port, key, cols, rows)
        if let err = mosh_client_last_error(c) { mosh_client_free(c); return String(cString: err) }
        client = c
        serverIP = ip; serverPort = port; serverKey = key; self.cols = cols; self.rows = rows
        moshLog("open \(cols)x\(rows)")
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            mosh_client_free(c)
            client = nil
            return "couldn't create the mosh wake pipe"
        }
        wakeRead = fds[0]; wakeWrite = fds[1]
        Self.setNonBlocking(wakeRead)
        Self.setNonBlocking(wakeWrite)
        // iOS suspends the loop + tears down our socket when backgrounded. On return
        // we (a) kick the loop, (b) re-assert the terminal size + force a full repaint
        // (the framebuffer/viewport desync that leaves content wrapping at the wrong
        // row), and (c) hop to a fresh socket if we'd gone stale. Observe both
        // notifications — willEnterForeground fires earliest; didBecomeActive is the
        // backstop — since either alone has proven unreliable in a SwiftUI-scene app.
        let willEnterForeground: (Notification) -> Void = { [weak self] note in
            guard let self else { return }
            self.lock.lock()
            self.appInForeground = true
            self.appIsActive = false
            self.lock.unlock()
            moshLog("foreground note=\(note.name.rawValue) wake=false")
        }
        let didBecomeActive: (Notification) -> Void = { [weak self] note in
            guard let self else { return }
            let now = Date().timeIntervalSinceReferenceDate
            self.lock.lock()
            let shouldResume = now - self.lastResumeRequestAt > 1.25
            self.appInForeground = true
            self.appIsActive = true
            if shouldResume {
                self.lastResumeRequestAt = now
                self.resumeRequested = true
            }
            self.lock.unlock()
            moshLog("foreground note=\(note.name.rawValue) shouldResume=\(shouldResume)")
            self.wake()
        }
        foregroundObservers.append(
            NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil, using: willEnterForeground))
        foregroundObservers.append(
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil, using: didBecomeActive))
        foregroundObservers.append(
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] note in
                guard let self else { return }
                self.lock.lock()
                self.appInForeground = false
                self.appIsActive = false
                self.pendingForegroundRecovery = true
                self.lock.unlock()
                moshLog("background note=\(note.name.rawValue)")
                self.wake()
            })
        queue.async { [weak self] in self?.runLoop() }
        return nil
    }

    func write(_ bytes: ArraySlice<UInt8>) {
        lock.lock(); pendingInput.append(contentsOf: bytes); lock.unlock()
        wake()
    }

    func resize(cols: Int32, rows: Int32) {
        lock.lock(); pendingResize = (cols, rows); self.cols = cols; self.rows = rows; lock.unlock()
        moshLog("resize \(cols)x\(rows)")
        wake()
    }

    func disconnect() {
        lock.lock(); stopRequested = true; lock.unlock()
        wake()
    }

    private func wake() {
        lock.lock()
        defer { lock.unlock() }
        guard wakeWrite >= 0 else { return }
        var b: UInt8 = 1
        _ = Darwin.write(wakeWrite, &b, 1)
    }

    private func runLoop() {
        while true {
            guard let c = client else { break }
            // Apply staged commands before touching mosh. When the app is
            // backgrounded, leave input/resize queued and park on the wake pipe
            // only; touching the UDP transport in the background has caused
            // process death during stale datagram recovery.
            lock.lock()
            let stop = stopRequested
            let transportAllowed = appInForeground && appIsActive
            let resume = transportAllowed && resumeRequested
            let foregroundRecovery = resume ? pendingForegroundRecovery : false
            if resume {
                resumeRequested = false
                pendingForegroundRecovery = false
            }
            let input: [UInt8]
            let resize: (Int32, Int32)?
            if transportAllowed {
                input = pendingInput
                pendingInput.removeAll(keepingCapacity: true)
                resize = pendingResize
                pendingResize = nil
            } else {
                input = []
                resize = nil
            }
            lock.unlock()

            if stop { break }
            guard transportAllowed else {
                waitForWakeOnly()
                continue
            }

            // Refresh mosh's frozen clock once per active iteration. Without this
            // every send/ack timer stalls after the first packet and local input
            // is never transmitted. See mosh_client_freeze_time / stmclient.cc.
            mosh_client_freeze_time()

            // Returning from the background.
            if resume {
                lastResumeAt = Date()
                let silent = Date().timeIntervalSince(lastContactAt)
                // The actual size mosh is drawing right now, vs the size we'll re-assert.
                var fbCols: Int32 = 0, fbRows: Int32 = 0
                mosh_client_fb_dims(c, &fbCols, &fbRows)
                moshLog("resume: silent=\(Int(silent))s ask=\(cols)x\(rows) fb=\(fbCols)x\(fbRows)")
                // If we'd gone silent past the stale threshold, iOS likely tore down
                // our suspended UDP socket — hop to a fresh one on the SAME connection
                // (preserves the crypto sequence the server's replay-protection needs;
                // a brand-new client would be rejected). mosh auto-hops only after 10s.
                let needsRecoveryWiggle = foregroundRecovery || silent > Self.staleThreshold
                if needsRecoveryWiggle {
                    moshLog("resume hop begin recovery=\(foregroundRecovery) silent=\(Int(silent))s")
                    mosh_client_hop(c)
                    mosh_client_prime_active_retry(c)
                    moshLog("resume hop end")
                }
                // Re-assert the terminal size (server redraws to match) and force a
                // full repaint — fixes the framebuffer/viewport desync that leaves the
                // screen wrapping at the wrong row with a gap after resume.
                moshLog("resume resize/repaint begin recovery=\(needsRecoveryWiggle)")
                if needsRecoveryWiggle, rows > 1 {
                    mosh_client_resize(c, cols, rows - 1)
                }
                mosh_client_resize(c, cols, rows)
                mosh_client_force_repaint(c)
                moshLog("resume resize/repaint end")
                // Arm the roam-failure watch only when we actually attempted a
                // recovery (a real silence gap). If the remote state never advances
                // past this point while the user types, the roam is wedged (send ok,
                // receive of state dead) and we'll fall back to a full reconnect.
                if needsRecoveryWiggle {
                    resumeStateNum = mosh_client_state_num(c)
                    resumeInputPushSeq = inputPushSeq
                    datagramsSinceResume = 0
                    validRecvSinceResume = 0
                    roamWatchActive = true
                    roamReconnectFired = false
                }
            }
            if !input.isEmpty {
                inputPushSeq += 1
                let inputSeq = inputPushSeq
                let inputSilent = Date().timeIntervalSince(lastContactAt)
                let recentlyResumed = lastResumeAt.map { Date().timeIntervalSince($0) <= Self.postResumeInputRecoveryWindow } ?? false
                awaitingOutputForInputSeq = inputSeq
                awaitingOutputSince = Date()
                lastAwaitingOutputLogAt = nil
                moshLog("input push seq=\(inputSeq) bytes=\(input.count) state=\(mosh_client_state_num(c))")
                input.withUnsafeBytes { raw in
                    mosh_client_push(c, raw.bindMemory(to: CChar.self).baseAddress, Int32(raw.count))
                }
                if recentlyResumed {
                    mosh_client_prime_active_retry(c)
                }
                if inputSilent > Self.staleThreshold {
                    mosh_client_prime_active_retry(c)
                    moshLog("input retry prime seq=\(inputSeq) silent=\(Int(inputSilent))s state=\(mosh_client_state_num(c))")
                }
            }
            if let (cols, rows) = resize {
                mosh_client_resize(c, cols, rows)
                // SwiftTerm reflows its OWN grid on a bounds change, so its on-screen
                // content diverges from mosh's last framebuffer. A normal diff frame
                // would then be applied to the wrong base — the wrong-row wrapping /
                // frozen display seen after an iPad multitasking resize. Force the
                // next frame to be an absolute full repaint so it re-syncs the view to
                // mosh regardless of what SwiftTerm reflowed to. (This also covers iPad
                // Stage Manager / split-view, where the foreground/resume path that
                // already force-repaints never fires — only this resize does.)
                mosh_client_force_repaint(c)
            }
            mosh_client_tick(c)

            // After a mosh port hop, the transport keeps the old UDP socket(s)
            // around briefly while sending on the newest one. Poll every socket;
            // polling only the first/old socket is exactly how resume can look
            // hung even though the new socket is sending.
            var moshFDs = [Int32](repeating: -1, count: 16)
            let moshFDCount = Int(mosh_client_fds(c, &moshFDs, Int32(moshFDs.count)))
            var fds = moshFDs.prefix(max(0, moshFDCount)).map {
                pollfd(fd: $0, events: Int16(POLLIN), revents: 0)
            }
            let wakeIndex = fds.count
            fds.append(pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0))
            // While the server is silent past the stale threshold, wake more often
            // so driveStaleRecovery() can re-prime/hop promptly instead of sleeping
            // up to a full second (or up to mosh's backed-off wait_ms).
            let silentBeforePoll = Date().timeIntervalSince(lastContactAt)
            let pollCeiling: Int32 = silentBeforePoll > Self.staleThreshold ? Self.staleRecoveryPollCeilingMs : 1000
            let timeout = max(1, min(mosh_client_wait_ms(c), pollCeiling))
            _ = fds.withUnsafeMutableBufferPointer { buf in
                poll(buf.baseAddress, nfds_t(buf.count), Int32(timeout))
            }

            if fds[wakeIndex].revents & Int16(POLLIN) != 0 { drainWakePipe() }
            let moshReadable = fds.prefix(wakeIndex).contains { $0.revents & Int16(POLLIN) != 0 }

            lock.lock()
            let transportStillAllowed = appInForeground && appIsActive
            let waitingForActive = appInForeground && !appIsActive
            if !transportStillAllowed, moshReadable {
                pendingForegroundRecovery = true
            }
            lock.unlock()
            guard transportStillAllowed else {
                if moshReadable {
                    let reason = waitingForActive ? "until active" : "after background"
                    moshLog("datagram deferred \(reason) ask=\(cols)x\(rows)")
                }
                continue
            }

            if moshReadable {                                   // a datagram arrived
                // Recovery is keyed off ELAPSED SILENCE, computed before we update
                // lastContactAt — NOT off staleReported. When iOS fully suspends the
                // app the run loop is frozen, so it never gets to flip staleReported;
                // on resume the first packet would otherwise update lastContactAt and
                // skip the repaint/wiggle entirely. The real gap survives suspension.
                let recovering = Date().timeIntervalSince(lastContactAt) > Self.staleThreshold
                // Drain EVERY queued datagram, not just one. recv() takes a single
                // datagram per call, and after a hop the server replays its state as
                // a burst; without draining, the catch-up trickles in one datagram
                // per loop iteration (slow, and each iteration re-polls).
                var drained = 0
                repeat {
                    if mosh_client_recv(c) == 1 { validRecvSinceResume += 1 }
                    drained += 1
                } while drained < Self.maxRecvDrainPerWake && Self.anyMoshFDReadable(c)
                lastContactAt = Date()
                datagramsSinceResume += drained
                // Contact resumed — let the next stale episode act immediately.
                lastStaleRecoveryPrimeAt = nil
                lastStaleRecoveryHopAt = nil
                if recovering {
                    lock.lock()
                    let active = appInForeground && appIsActive
                    if !active { pendingForegroundRecovery = true }
                    lock.unlock()
                    guard active else {
                        moshLog("recovering stale datagram deferred until active ask=\(cols)x\(rows)")
                        continue
                    }
                    forceForegroundRecovery(c, reason: "stale datagram")
                }
            }
            mosh_client_tick(c)
            if let ansi = mosh_client_drain_ansi(c) {
                let bytes = Array(String(cString: ansi).utf8)
                free(ansi)
                ansiDrainSeq += 1
                let state = mosh_client_state_num(c)
                let waitedMs: Int?
                if let started = awaitingOutputSince {
                    waitedMs = Int(Date().timeIntervalSince(started) * 1000)
                } else {
                    waitedMs = nil
                }
                let inputLabel = awaitingOutputForInputSeq.map { String($0) } ?? "-"
                let waitLabel = waitedMs.map { String($0) } ?? "-"
                moshLog("drain ansi seq=\(ansiDrainSeq) bytes=\(bytes.count) state=\(state) inputSeq=\(inputLabel) waitMs=\(waitLabel)")
                awaitingOutputForInputSeq = nil
                awaitingOutputSince = nil
                lastAwaitingOutputLogAt = nil
                lastInputRecoveryAt = nil
                onOutput?(bytes[...])
                // Note when the rendered framebuffer size changes — a value that
                // diverges from our asked size (cols×rows) is the display desync.
                var fbCols: Int32 = 0, fbRows: Int32 = 0
                mosh_client_fb_dims(c, &fbCols, &fbRows)
                if fbCols != lastFbCols || fbRows != lastFbRows {
                    lastFbCols = fbCols; lastFbRows = fbRows
                    moshLog("frame fb=\(fbCols)x\(fbRows) ask=\(cols)x\(rows)")
                }
            } else if let err = mosh_client_last_error(c) {
                let message = String(cString: err)
                if message.isEmpty == false && message != lastReportedClientError {
                    lastReportedClientError = message
                    moshLog("client error: \(message)")
                }
            } else if let inputSeq = awaitingOutputForInputSeq, let started = awaitingOutputSince {
                let now = Date()
                let pendingAge = now.timeIntervalSince(started)
                if pendingAge > 0.75,
                   lastAwaitingOutputLogAt.map({ now.timeIntervalSince($0) > 1.0 }) ?? true {
                    lastAwaitingOutputLogAt = now
                    moshLog("drain pending no ansi inputSeq=\(inputSeq) ageMs=\(Int(pendingAge * 1000)) state=\(mosh_client_state_num(c))")
                }
                let recentlyResumed = lastResumeAt.map { now.timeIntervalSince($0) <= Self.postResumeInputRecoveryWindow } ?? false
                let silent = now.timeIntervalSince(lastContactAt)
                let shouldRecoverPostResume = recentlyResumed && pendingAge > Self.inputRecoveryDelay
                let shouldHopForStale = pendingAge > 1.5 && silent > Self.staleThreshold
                if (shouldRecoverPostResume || shouldHopForStale),
                   lastInputRecoveryAt.map({ now.timeIntervalSince($0) > Self.inputRecoveryCooldown }) ?? true {
                    lastInputRecoveryAt = now
                    let reason = shouldHopForStale ? "stale input" : "post-resume input"
                    moshLog("input recovery begin reason=\(reason) inputSeq=\(inputSeq) ageMs=\(Int(pendingAge * 1000)) silent=\(Int(silent))s state=\(mosh_client_state_num(c))")
                    if shouldHopForStale {
                        mosh_client_hop(c)
                    }
                    mosh_client_prime_active_retry(c)
                    forceForegroundRecovery(c, reason: reason)
                    mosh_client_tick(c)
                    moshLog("input recovery end reason=\(reason) inputSeq=\(inputSeq) state=\(mosh_client_state_num(c))")
                }
            }
            // No datagram drove recovery above and we're not waiting on an echo for
            // typed input (input-recovery owns that case): if the server has gone
            // silent, keep mosh's active-retry window open so a torn-down socket
            // re-establishes instead of freezing. Skip the resume iteration, which
            // already hopped/primed.
            let silent = Date().timeIntervalSince(lastContactAt)
            if silent > Self.staleThreshold, awaitingOutputForInputSeq == nil, !resume {
                driveStaleRecovery(c, silent: silent)
            }
            // Roam-failure detection: after a recovery, if the remote state never
            // advanced past the resume snapshot AND the user has typed into it, the
            // roam is wedged — input reaches the server (send works) but no new state
            // comes back (receive dead). Datagrams may even be arriving (acks /
            // duplicates), so silence alone can't catch this. Fall back to a full
            // re-bootstrap, which re-attaches to the same server-side session.
            if roamWatchActive, !roamReconnectFired, let resumedAt = lastResumeAt {
                if mosh_client_state_num(c) > resumeStateNum {
                    roamWatchActive = false                      // roam re-established
                } else if inputPushSeq > resumeInputPushSeq,
                          Date().timeIntervalSince(resumedAt) > Self.roamFailTimeout {
                    roamReconnectFired = true
                    roamWatchActive = false
                    // validRecv is the discriminator: 0 ⇒ no real peer packets are
                    // arriving (dead roamed path), >0 with frozen state ⇒ packets
                    // decrypt but mosh drops them in-protocol (reference-state reject).
                    moshLog("roam failed: state stuck=\(mosh_client_state_num(c)) inputs=\(inputPushSeq - resumeInputPushSeq) datagrams=\(datagramsSinceResume) validRecv=\(validRecvSinceResume) silent=\(Int(Date().timeIntervalSince(lastContactAt)))s — requesting reconnect")
                    let handler = lock.withLock { onRoamFailedHandler }
                    handler?()
                }
            }
            // Flag staleness on transition (the loop wakes at least ~1/s, so this
            // is checked promptly without a separate timer).
            let stale = Date().timeIntervalSince(lastContactAt) > Self.staleThreshold
            if stale != staleReported { staleReported = stale; onLiveness?(stale) }
        }
        teardown()
    }

    private func waitForWakeOnly() {
        guard wakeRead >= 0 else { return }
        var fd = pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
        _ = withUnsafeMutablePointer(to: &fd) { poll($0, 1, 1000) }
        if fd.revents & Int16(POLLIN) != 0 { drainWakePipe() }
    }

    private func drainWakePipe() {
        guard wakeRead >= 0 else { return }
        var trash = [UInt8](repeating: 0, count: 64)
        while Darwin.read(wakeRead, &trash, trash.count) > 0 {}
    }

    /// Foreground + active, server silent past the stale threshold, and no typed
    /// input is awaiting an echo (input-recovery handles that case). Upstream mosh
    /// stops resending unacked state ACTIVE_RETRY_TIMEOUT (~10s) after it last heard
    /// from the server, so a session whose UDP socket iOS tore down can sit frozen —
    /// input reaches the server once but the path is never re-established and no
    /// output flows back — until the user types or re-foregrounds. Keep the path
    /// alive: refresh the active-retry window (prime) every second and, once we've
    /// been silent a little longer, hop to a fresh socket (new NAT binding) every few
    /// seconds, then tick to actually send.
    private func driveStaleRecovery(_ c: OpaquePointer, silent: TimeInterval) {
        let now = Date()
        var acted = false
        if lastStaleRecoveryPrimeAt.map({ now.timeIntervalSince($0) >= Self.staleRecoveryPrimeInterval }) ?? true {
            lastStaleRecoveryPrimeAt = now
            mosh_client_prime_active_retry(c)
            acted = true
        }
        if silent >= Self.staleThreshold * 1.5,
           lastStaleRecoveryHopAt.map({ now.timeIntervalSince($0) >= Self.staleRecoveryHopInterval }) ?? true {
            lastStaleRecoveryHopAt = now
            mosh_client_hop(c)
            acted = true
        }
        if acted {
            mosh_client_tick(c)
            moshLog("stale recovery prime/hop silent=\(Int(silent))s state=\(mosh_client_state_num(c))")
        }
    }

    /// Non-blocking check: is any of mosh's current sockets readable right now?
    /// Used to drain a burst of datagrams within a single wake.
    private static func anyMoshFDReadable(_ c: OpaquePointer) -> Bool {
        var fdbuf = [Int32](repeating: -1, count: 16)
        let n = Int(mosh_client_fds(c, &fdbuf, Int32(fdbuf.count)))
        guard n > 0 else { return false }
        var fds = fdbuf.prefix(n).map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        let rc = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 0) }
        guard rc > 0 else { return false }
        return fds.contains { $0.revents & Int16(POLLIN) != 0 }
    }

    private func forceForegroundRecovery(_ c: OpaquePointer, reason: String) {
        // Recovered after a stale gap (background → resume). Two things, both of
        // which a manual resize was doing for us:
        // (1) force our renderer to redraw ABSOLUTELY, not as a diff against the
        //     stale pre-gap baseline (else stray cells);
        // (2) nudge the SERVER to redraw + re-home its cursor with a real size
        //     change. tmux/screen only reliably re-home on SIGWINCH, so rows-1 →
        //     rows forces two SIGWINCHes ending at the real size.
        moshLog("foreground recovery begin reason=\(reason) ask=\(cols)x\(rows)")
        if rows > 1 { mosh_client_resize(c, cols, rows - 1) }
        mosh_client_resize(c, cols, rows)
        mosh_client_force_repaint(c)
        moshLog("foreground recovery end reason=\(reason)")
    }

    private func teardown() {
        moshLog("teardown")
        foregroundObservers.forEach { NotificationCenter.default.removeObserver($0) }
        foregroundObservers.removeAll()
        if let c = client { mosh_client_free(c); client = nil }
        lock.lock()
        let readFD = wakeRead
        let writeFD = wakeWrite
        wakeRead = -1
        wakeWrite = -1
        let notify = !closeNotified
        closeNotified = true
        let closed = onClosedHandler
        lock.unlock()
        if readFD >= 0 { close(readFD) }
        if writeFD >= 0 { close(writeFD) }
        if notify { closed?(nil) }   // user-initiated stop = clean
    }

    private static func setNonBlocking(_ fd: Int32) {
        guard fd >= 0 else { return }
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
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
