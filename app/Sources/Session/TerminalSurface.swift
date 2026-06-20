import UIKit
import AudioToolbox
import QuartzCore
import SwiftTerm

/// The persistent UIKit terminal for one session: the `TerminalView`, its
/// delegate wiring, and a `TerminalHandle`. Kept alive by `TerminalSurfaceCache`
/// for the life of the session so switching tabs preserves each terminal's
/// on-screen buffer and scrollback — the view is re-embedded, not rebuilt.
@MainActor
final class TerminalSurface: NSObject, @preconcurrency TerminalViewDelegate {
    let session: TerminalSession
    let view: ZoomableTerminalView
    let handle = TerminalHandle()

    private var appliedThemeId: String?
    var onZoomChange: ((CGFloat) -> Void)?
    private var foregroundObservers: [NSObjectProtocol] = []
    private var foregroundRefreshWork: [DispatchWorkItem] = []
    private var lastForegroundResyncAt: CFTimeInterval = 0
    private var outputEnqueueSeq = 0
    private var feedSeq = 0

    init(session: TerminalSession, themeId: String, fontFamily: String, fontSize: CGFloat) {
        self.session = session
        self.view = ZoomableTerminalView(frame: .zero, font: nil)
        super.init()

        view.terminalDelegate = self
        view.onZoomChange = { [weak self] newSize in self?.onZoomChange?(newSize) }
        view.onSendBytes = { [weak self] bytes in self?.session.write(bytes[...]) }
        view.onImageDropped = { [weak self] data, ext in self?.session.uploadImage(data, ext: ext) }
        view.installZoomGestures()
        view.setFont(family: fontFamily, size: fontSize)
        TerminalTheme.named(themeId).apply(to: view)
        appliedThemeId = themeId
        handle.terminal = view
        handle.captureAccessory()

        let scrollback = UserDefaults.standard.integer(forKey: SettingsKey.scrollback)
        if scrollback > 0 { view.getTerminal().changeScrollback(scrollback) }
        applyPrefs()

        // The session forwards output from whichever transport is current, so a
        // reconnect swaps the underlying transport without re-wiring here.
        // Output is coalesced: chunks accumulate and we feed once per runloop
        // turn. SwiftTerm schedules its own display update from `feedFinish()`;
        // explicit full-screen refreshes are reserved for foreground/re-embed
        // recovery paths.
        session.onOutput = { [weak self] bytes in
            DispatchQueue.main.async {
                guard let self else { return }
                self.outputEnqueueSeq += 1
                let seq = self.outputEnqueueSeq
                let before = self.pendingFeed.count
                self.pendingFeed.append(contentsOf: bytes)
                DiagLog.log("terminal", "output enqueue seq=\(seq) bytes=\(bytes.count) pending=\(before)->\(self.pendingFeed.count) active=\(UIApplication.shared.applicationState.rawValue) window=\(self.view.window != nil)")
                self.scheduleFlush()
            }
        }

        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.resyncAfterForeground() }
        }
        foregroundObservers.append(
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: refresh))
        foregroundObservers.append(
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancelForegroundRefreshForBackground() }
            })
    }

    deinit {
        foregroundObservers.forEach { NotificationCenter.default.removeObserver($0) }
        foregroundRefreshWork.forEach { $0.cancel() }
    }

    private var pendingFeed: [UInt8] = []
    private var flushScheduled = false

    /// Drain accumulated output on the next runloop turn — coalescing every chunk
    /// that arrived in between into a single terminal feed.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard !self.pendingFeed.isEmpty else { return }
            let chunk = self.pendingFeed
            self.pendingFeed.removeAll(keepingCapacity: true)
            self.feedSeq += 1
            let seq = self.feedSeq
            DiagLog.log("terminal", "feed begin seq=\(seq) bytes=\(chunk.count) updateBefore=\(self.updateRangeDescription()) window=\(self.view.window != nil) bounds=\(Int(self.view.bounds.width))x\(Int(self.view.bounds.height))")
            self.view.noteFeedForDiagnostics(seq: seq, bytes: chunk.count)
            self.view.feed(byteArray: chunk[...])
            DiagLog.log("terminal", "feed end seq=\(seq) updateAfter=\(self.updateRangeDescription()) terminal=\(self.view.getTerminal().cols)x\(self.view.getTerminal().rows)")
        }
    }

    private func updateRangeDescription() -> String {
        guard let range = view.getTerminal().getUpdateRange() else { return "nil" }
        return "\(range.startY)-\(range.endY)"
    }

    /// Force a full repaint — used when the view is re-embedded after a tab
    /// switch so the preserved buffer redraws immediately.
    func refresh() {
        view.getTerminal().updateFullScreen()
        view.setNeedsDisplay(view.bounds)
    }

    func apply(themeId: String, fontFamily: String, fontSize: CGFloat, hardwareKeyboard: Bool) {
        view.setFont(family: fontFamily, size: fontSize)
        handle.setAccessorySuppressed(hardwareKeyboard)
        applyPrefs()
        if appliedThemeId != themeId {
            appliedThemeId = themeId
            TerminalTheme.named(themeId).apply(to: view)
            view.getTerminal().updateFullScreen()
            view.setNeedsDisplay(view.bounds)
        }
    }

    /// Foregrounding can deliver the mosh resume repaint before UIKit has finished
    /// laying out the terminal. Push SwiftTerm's current geometry immediately
    /// (bypassing the drag debounce) and repaint locally, then repeat once after
    /// the foreground transition settles.
    func resyncAfterForeground() {
        guard UIApplication.shared.applicationState == .active else {
            DiagLog.log("terminal", "foreground resync skipped: app not active")
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastForegroundResyncAt > 0.15 else {
            DiagLog.log("terminal", "foreground resync skipped duplicate")
            return
        }
        lastForegroundResyncAt = now
        cancelForegroundRefreshWork()
        DiagLog.log("terminal", "foreground resync scheduled bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height)) window=\(view.window != nil)")

        scheduleForegroundRedraw(after: 0.05)
        scheduleForegroundRedraw(after: 0.20)
        scheduleForegroundRedraw(after: 0.65)
        scheduleForegroundRedraw(after: 1.20)
    }

    private func cancelForegroundRefreshForBackground() {
        cancelForegroundRefreshWork()
        DiagLog.log("terminal", "foreground redraw cancelled: background")
    }

    private func scheduleForegroundRedraw(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.forceCurrentSizeAndRedraw() }
        foregroundRefreshWork.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelForegroundRefreshWork() {
        foregroundRefreshWork.forEach { $0.cancel() }
        foregroundRefreshWork.removeAll(keepingCapacity: true)
    }

    private func forceCurrentSizeAndRedraw() {
        guard UIApplication.shared.applicationState == .active else {
            DiagLog.log("terminal", "redraw skipped: app not active")
            return
        }
        guard view.window != nil else {
            DiagLog.log("terminal", "redraw skipped: no window")
            return
        }
        guard view.bounds.width > 1, view.bounds.height > 1 else {
            DiagLog.log("terminal", "redraw skipped: bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
            return
        }
        view.layoutIfNeeded()
        let terminal = view.getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else {
            DiagLog.log("terminal", "redraw skipped: terminal=\(terminal.cols)x\(terminal.rows)")
            return
        }
        DiagLog.log("terminal", "redraw force resize=\(terminal.cols)x\(terminal.rows) bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
        sendResize(cols: terminal.cols, rows: terminal.rows, force: true)
        view.snapToLiveTail(reason: "foreground")
        terminal.updateFullScreen()
        view.setNeedsDisplay(view.bounds)
    }

    /// Apply the live-changeable preferences (cursor, Option-as-Meta).
    private func applyPrefs() {
        let d = UserDefaults.standard
        let shape = CursorShape(rawValue: d.string(forKey: SettingsKey.cursorStyle) ?? "block") ?? .block
        view.getTerminal().setCursorStyle(shape.swiftTerm(blink: d.bool(forKey: SettingsKey.cursorBlink)))
        view.optionAsMetaKey = d.bool(forKey: SettingsKey.optionAsMeta)
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) { session.write(data) }

    // Coalesce resize churn: a Stage Manager / split-view drag fires ~60 layout
    // passes a second, and each session.resize forces a full mosh repaint. Skip
    // no-op repeats and debounce so only the settled size reaches the transport.
    private var lastSentCols: Int = -1
    private var lastSentRows: Int = -1
    private var pendingResize: DispatchWorkItem?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard UIApplication.shared.applicationState != .background else {
            DiagLog.log("terminal", "resize skipped: app background \(newCols)x\(newRows)")
            return
        }
        // No-op suppression — the same size during a drag costs nothing.
        if newCols == lastSentCols && newRows == lastSentRows { return }
        pendingResize?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingResize = nil
            self.sendResize(cols: newCols, rows: newRows, force: false)
        }
        pendingResize = work
        // Trailing debounce: only the last size in a ~110ms quiet window is sent,
        // and the final size always wins (every change reschedules this).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: work)
    }

    private func sendResize(cols: Int, rows: Int, force: Bool) {
        guard UIApplication.shared.applicationState != .background else {
            DiagLog.log("terminal", "send resize skipped: app background \(cols)x\(rows)")
            return
        }
        guard cols > 0, rows > 0 else { return }
        pendingResize?.cancel()
        pendingResize = nil
        if !force, cols == lastSentCols, rows == lastSentRows { return }
        lastSentCols = cols
        lastSentRows = rows
        session.resize(cols: Int32(cols), rows: Int32(rows))
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // Only follow http(s) links from terminal output — never arbitrary schemes
        // (tel:, file:, custom app schemes) that remote output could inject.
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {
        switch UserDefaults.standard.string(forKey: SettingsKey.bellMode) {
        case "haptic": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "sound": AudioServicesPlaySystemSound(1057)
        default: break   // silent
        }
    }
    func clipboardCopy(source: TerminalView, content: Data) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Vends one persistent `TerminalSurface` per session id.
@MainActor
@Observable
final class TerminalSurfaceCache {
    private var surfaces: [UUID: TerminalSurface] = [:]

    func surface(for session: TerminalSession, themeId: String, fontFamily: String, fontSize: CGFloat) -> TerminalSurface {
        if let existing = surfaces[session.id] { return existing }
        let surface = TerminalSurface(session: session, themeId: themeId, fontFamily: fontFamily, fontSize: fontSize)
        surfaces[session.id] = surface
        return surface
    }

    func drop(_ id: UUID) { surfaces[id] = nil }
}
