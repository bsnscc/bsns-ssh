import SwiftUI
import UIKit
import SwiftTerm
import UniformTypeIdentifiers
import QuartzCore

private let minFontSize: CGFloat = 8
private let maxFontSize: CGFloat = 30
private let defaultFontSize: CGFloat = 15

/// A terminal bound to a `TerminalSession`: zoom (pinch, ⌘+/⌘-/⌘0, buttons),
/// theme + font selection, copy/paste, find, and reconnect-on-drop.
struct LiveTerminalScreen: View {
    let session: TerminalSession

    @Environment(TerminalSurfaceCache.self) private var surfaceCache

    @AppStorage("terminal.fontSize") private var fontSize: Double = Double(defaultFontSize)
    @AppStorage("terminal.themeId") private var themeId: String = TerminalTheme.bsnsDark.id
    @AppStorage("terminal.fontFamily") private var fontFamily: String = TerminalFont.families[0]
    @AppStorage(SettingsKey.cursorStyle) private var cursorStyle = "block"
    @AppStorage(SettingsKey.cursorBlink) private var cursorBlink = true
    @AppStorage(SettingsKey.optionAsMeta) private var optionAsMeta = true
    @AppStorage(SettingsKey.keepAwake) private var keepAwake = false
    @AppStorage(SettingsKey.showKeyBar) private var showKeyBar = true

    @State private var keyboardUp = false
    @State private var hwKeyboard = HardwareKeyboardMonitor()
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var showForwards = false
    @State private var showSnippets = false
    @State private var showHistory = false
    @State private var showHelp = false
    @State private var muxScrollActive = false
    @FocusState private var findFocused: Bool

    private var theme: TerminalTheme { TerminalTheme.named(themeId) }
    private var surface: TerminalSurface {
        surfaceCache.surface(for: session, themeId: themeId, fontFamily: fontFamily, fontSize: CGFloat(fontSize))
    }
    private var handle: TerminalHandle { surface.handle }

    var body: some View {
        VStack(spacing: 0) {
            controlRow            // tabs + actions on ONE row (no separate nav bar)
            if showFind { findBar }
            statusBanner
            TerminalSurfaceView(surface: surface,
                                fontSize: Binding(get: { CGFloat(fontSize) }, set: { fontSize = Double($0) }),
                                themeId: themeId,
                                fontFamily: fontFamily,
                                hardwareKeyboard: hwKeyboard.isConnected,
                                prefs: "\(cursorStyle)\(cursorBlink)\(optionAsMeta)",
                                muxScrollActive: $muxScrollActive)
                .overlay(alignment: .top) { transferBanner }
            // Our key row is redundant with SwiftTerm's soft-keyboard accessory,
            // so only show it when the soft keyboard is down. With a physical
            // keyboard it collapses to just Esc (see TerminalKeyBar.minimal).
            if !keyboardUp && showKeyBar {
                Divider().overlay(Color(theme.ansi[8].uiColor).opacity(0.5))
                TerminalKeyBar(session: session, handle: handle, theme: theme,
                               minimal: hwKeyboard.isConnected,
                               muxScrollActive: $muxScrollActive)
            }
        }
            .ignoresSafeArea(.container, edges: .bottom)
            .toolbar(.hidden, for: .navigationBar)   // our controlRow replaces the nav bar
            .onAppear { hwKeyboard.start(); devFindTest(); UIApplication.shared.isIdleTimerDisabled = keepAwake }
            // Leaving the terminal (e.g. switching tabs) must NOT disconnect —
            // the session lives in the store until explicitly closed.
            .onDisappear {
                hwKeyboard.stop()
                UIApplication.shared.isIdleTimerDisabled = false
                muxScrollActive = false
                handle.setRemoteScrollMode(false)
            }
            .onChange(of: keepAwake) { _, v in UIApplication.shared.isIdleTimerDisabled = v }
            .onChange(of: muxScrollActive) { _, active in handle.setRemoteScrollMode(active) }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
            }
            .sheet(isPresented: $showForwards) { PortForwardsView(session: session) }
            .sheet(isPresented: $showSnippets) {
                SnippetPicker { snip in session.runCommand(snip.command) }
            }
            .sheet(isPresented: $showHistory) {
                CommandHistoryPicker { cmd in session.runCommand(cmd) }
            }
            .sheet(isPresented: $showHelp) {
                NavigationStack { TerminalHelpView() }
            }
    }

    /// One row: the session tabs (scrollable, left) and the terminal actions
    /// (right) — replaces the otherwise half-empty nav bar + its own tab row.
    private var controlRow: some View {
        HStack(spacing: 2) {
            SessionTabBar(activeID: session.id)
            terminalActions
                .padding(.trailing, 6)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var terminalActions: some View {
        HStack(spacing: 2) {
            Button { toggleFind() } label: { Image(systemName: "magnifyingglass") }
                .accessibilityLabel("Find")
            Button { setZoom(CGFloat(fontSize) - 1) } label: { Image(systemName: "textformat.size.smaller") }
                .accessibilityLabel("Decrease text size")
            Button { setZoom(CGFloat(fontSize) + 1) } label: { Image(systemName: "textformat.size.larger") }
                .accessibilityLabel("Increase text size")
            settingsMenu
        }
        .labelStyle(.iconOnly)
    }

    @ViewBuilder private var statusBanner: some View {
        switch session.status {
        case .connected:
            EmptyView()
        case .connecting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reconnecting…").font(.callout)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.bar)
        case .disconnected(let reason):
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.orange)
                Text(reason.map { "Disconnected — \($0)" } ?? "Disconnected")
                    .font(.callout).lineLimit(2)
                Spacer()
                Button("Reconnect") { session.reconnect() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.bar)
        }
    }

    /// Transient banner for an in-flight image drop/paste upload — floats over the
    /// top of the terminal so it doesn't reflow the buffer, then auto-dismisses.
    @ViewBuilder private var transferBanner: some View {
        if let status = session.transferStatus {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled").foregroundStyle(Brand.accent)
                Text(status).font(.callout).lineLimit(2)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.bar, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .padding(.top, 8)
            .shadow(radius: 4, y: 1)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: session.transferStatus)
        }
    }

    private var findBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in output", text: $findQuery)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($findFocused)
                .submitLabel(.search)
                .onSubmit { handle.find(findQuery) }
                .onChange(of: findQuery) { _, q in handle.find(q) }
            if !findQuery.isEmpty {
                Text(handle.matchCount == 0 ? "none" : "\(handle.currentMatchOrdinal)/\(handle.matchCount)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button { handle.findPrev() } label: { Image(systemName: "chevron.up") }
                .disabled(handle.matchCount == 0)
                .accessibilityLabel("Previous match")
            Button { handle.findNext() } label: { Image(systemName: "chevron.down") }
                .disabled(handle.matchCount == 0)
                .accessibilityLabel("Next match")
            Button { closeFind() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .accessibilityLabel("Close find")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func toggleFind() {
        if showFind { closeFind() } else { showFind = true; findFocused = true }
    }

    private func closeFind() {
        showFind = false
        findQuery = ""
        handle.clearFind()
    }

    private var settingsMenu: some View {
        Menu {
            Button { handle.paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            Button { handle.selectAll() } label: { Label("Select All", systemImage: "selection.pin.in.out") }

            let count = session.forwards.count
            Button { showForwards = true } label: {
                Label(count == 0 ? "Port Forwarding…" : "Port Forwarding (\(count))…",
                      systemImage: "arrow.left.arrow.right")
            }
            Button { showSnippets = true } label: { Label("Run a snippet…", systemImage: "text.badge.plus") }
            Button { showHistory = true } label: { Label("Command history…", systemImage: "clock.arrow.circlepath") }
            Button { showHelp = true } label: { Label("Terminal Help…", systemImage: "questionmark.circle") }

            Picker("Theme", selection: $themeId) {
                ForEach(TerminalTheme.all) { Text($0.id).tag($0.id) }
            }
            Picker("Font", selection: $fontFamily) {
                ForEach(TerminalFont.families, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("More actions")
        }
    }

    private func setZoom(_ size: CGFloat) {
        fontSize = Double(min(maxFontSize, max(minFontSize, size)))
    }

    /// Dev hook: BSNS_DEV_FINDTEST=<term> auto-opens find on that term after
    /// output arrives, so the match highlight can be screenshotted headlessly.
    /// DEBUG-only — it writes commands into a session, so it must not exist in release.
    private func devFindTest() {
        #if DEBUG
        guard let term = ProcessInfo.processInfo.environment["BSNS_DEV_FINDTEST"], !term.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)   // let the shell prompt appear
            let gen = "for i in $(seq 1 80); do echo \"line $i \(term)-$i marker\"; done\n"
            session.write(Array(gen.utf8)[...])
            try? await Task.sleep(nanoseconds: 2_500_000_000)   // let output arrive
            showFind = true
            findQuery = term
            _ = handle.find(term)
        }
        #endif
    }
}

/// Lets the SwiftUI toolbar reach into the live `TerminalView` for paste/select,
/// and toggle SwiftTerm's built-in keyboard accessory (its F-key row), which we
/// suppress when a physical keyboard is attached.
@Observable
final class TerminalHandle {
    weak var terminal: TerminalView?
    private var defaultAccessory: UIView?

    func captureAccessory() { defaultAccessory = terminal?.inputAccessoryView }

    func setAccessorySuppressed(_ suppressed: Bool) {
        guard let terminal else { return }
        let desired = suppressed ? nil : defaultAccessory
        guard terminal.inputAccessoryView !== desired else { return }
        terminal.inputAccessoryView = desired
        terminal.reloadInputViews()
    }

    func paste() { terminal?.paste(nil) }
    func selectAll() { terminal?.selectAll(nil) }
    func setRemoteScrollMode(_ active: Bool) { (terminal as? ZoomableTerminalView)?.setRemoteScrollMode(active) }

    // MARK: Find in scrollback

    private struct FindMatch { let row: Int; let col: Int; let length: Int }
    private var matches: [FindMatch] = []
    private var matchIndex = 0
    private var linesTop = 0
    private var maxYDisp = 0
    @ObservationIgnored private var highlightView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.42)
        v.layer.cornerRadius = 2
        v.isUserInteractionEnabled = false
        v.isHidden = true
        return v
    }()

    /// Search the whole scrollback for `query`; scrolls to the last (most recent)
    /// match and returns the total count. `getScrollInvariantLine` reads any line
    /// regardless of the current scroll position, so this never disturbs the view.
    @discardableResult
    func find(_ query: String) -> Int {
        matches = []
        guard let t = terminal?.getTerminal(), !query.isEmpty else { hideHighlight(); return 0 }
        let needle = query.lowercased()

        var rows: [(row: Int, text: String)] = []
        var started = false
        var r = 0
        let cap = 50_000
        while r < cap {
            if let line = t.getScrollInvariantLine(row: r) {
                started = true
                rows.append((r, line.translateToString(trimRight: true)))
            } else if started {
                break
            }
            r += 1
        }
        guard let first = rows.first, let last = rows.last else { hideHighlight(); return 0 }
        linesTop = first.row
        let lineCount = last.row - first.row + 1
        maxYDisp = max(0, lineCount - t.rows)

        matches = rows.compactMap { row -> FindMatch? in
            guard let range = row.text.lowercased().range(of: needle) else { return nil }
            let col = row.text.distance(from: row.text.startIndex, to: range.lowerBound)
            return FindMatch(row: row.row, col: col, length: needle.count)
        }
        matchIndex = matches.count - 1   // start at the most recent match
        scrollToMatch()
        return matches.count
    }

    /// 1-based position of the current match, or 0 if none.
    var currentMatchOrdinal: Int { matches.isEmpty ? 0 : matchIndex + 1 }
    var matchCount: Int { matches.count }

    func findNext() { advance(by: 1) }
    func findPrev() { advance(by: -1) }

    private func advance(by delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        scrollToMatch()
    }

    private func scrollToMatch() {
        guard !matches.isEmpty, let tv = terminal else { hideHighlight(); return }
        let rows = tv.getTerminal().rows
        let match = matches[matchIndex]
        // Land the match about a third from the top so context above is visible.
        let target = min(max(0, match.row - linesTop - rows / 3), maxYDisp)
        tv.scrollTo(row: target)
        tv.setNeedsDisplay(tv.bounds)
        positionHighlight(match: match)
    }

    /// Box the current match. The TerminalView is a UIScrollView, so the overlay
    /// lives in CONTENT space (it scrolls with the text): content y = the match's
    /// absolute buffer-line index × cell height. Cell metrics are computed exactly
    /// as SwiftTerm's `computeFontDimensions`, so the box lines up with the cells.
    private func positionHighlight(match: FindMatch) {
        guard let tv = terminal else { hideHighlight(); return }
        let cell = cellSize(font: tv.font)
        let contentRow = match.row - linesTop
        highlightView.frame = CGRect(
            x: CGFloat(match.col) * cell.width,
            y: CGFloat(contentRow) * cell.height,
            width: CGFloat(match.length) * cell.width,
            height: cell.height)
        if highlightView.superview !== tv { tv.addSubview(highlightView) }
        tv.bringSubviewToFront(highlightView)
        highlightView.isHidden = false
    }

    private func cellSize(font: UIFont) -> CGSize {
        let h = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        let w = ("W" as NSString).size(withAttributes: [.font: font]).width
        let scale = terminal?.window?.screen.scale ?? UIScreen.main.scale
        return CGSize(width: ceil(w * scale) / scale, height: ceil(h * scale) / scale)
    }

    private func hideHighlight() { highlightView.isHidden = true }

    func clearFind() {
        matches = []
        hideHighlight()
        terminal?.scrollTo(row: maxYDisp)   // back to the live tail
    }
}

/// SwiftTerm's `TerminalView` with font-size zoom via pinch and ⌘ keys.
///
/// We use the default CoreGraphics renderer (its native caret sits in the right
/// cell — the Metal renderer's own cursor was permanently offset). CoreGraphics
/// relies on dirty-region tracking; foreground and re-embed recovery force a
/// repaint, while normal remote output stays on SwiftTerm's incremental path.
final class ZoomableTerminalView: TerminalView {
    var onZoomChange: ((CGFloat) -> Void)?
    /// Send raw bytes to the remote (set by the surface → session.write).
    var onSendBytes: (([UInt8]) -> Void)?
    /// Keeps SwiftUI controls in sync when a gesture enters multiplexer scroll mode.
    var onRemoteScrollModeChanged: ((Bool) -> Void)?
    /// An image was dropped or pasted onto the terminal — (PNG/JPEG data, ext).
    /// Set by the surface → session.uploadImage.
    var onImageDropped: ((Data, String) -> Void)?
    private var dropInteractionInstalled = false
    private var remoteScrollPanGesture: UIPanGestureRecognizer?
    private var remoteScrollMode = false
    private var remoteScrollAccumulator: CGFloat = 0
    private var scrollEnabledBeforeRemoteScroll = true
    private var autoMuxScrollArmed = false
    private var editMenu: UIEditMenuInteraction?
    private var currentSize: CGFloat = defaultFontSize
    private var pinchStart: CGFloat = defaultFontSize
    private var fontFamily: String = TerminalFont.families[0]
    private var diagnosticDrawSeq = 0
    private var diagnosticLastFeedSeq = 0
    private var diagnosticLastFeedBytes = 0
    private var diagnosticDrawLogUntil: CFTimeInterval = 0

    /// Re-embedded into a window after leaving and returning to the terminal
    /// (home → back, or a tab switch). The view + its buffer are cached and
    /// preserved, but a kept buffer won't repaint on its own — and an idle mosh
    /// session produces no new output to trigger a draw — so it shows blank until
    /// something happens. Force a full repaint once the view has laid out in the
    /// new window. (SSH usually escapes this because its shell emits something;
    /// mosh, being idle, does not — which is why this read as a mosh bug.)
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.snapToLiveTail(reason: "window")
            self.getTerminal().updateFullScreen()
            self.setNeedsDisplay(self.bounds)
        }
    }

    func noteFeedForDiagnostics(seq: Int, bytes: Int) {
        diagnosticLastFeedSeq = seq
        diagnosticLastFeedBytes = bytes
        diagnosticDrawLogUntil = CACurrentMediaTime() + 2.0
        let drawCountAtFeed = diagnosticDrawSeq
        scheduleDrawWatch(feedSeq: seq, bytes: bytes, drawCountAtFeed: drawCountAtFeed, after: 0.25)
        scheduleDrawWatch(feedSeq: seq, bytes: bytes, drawCountAtFeed: drawCountAtFeed, after: 1.20)
    }

    private func scheduleDrawWatch(feedSeq: Int, bytes: Int, drawCountAtFeed: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.diagnosticLastFeedSeq == feedSeq,
                  self.diagnosticDrawSeq == drawCountAtFeed else { return }
            DiagLog.log("terminal", "draw pending feedSeq=\(feedSeq) bytes=\(bytes) afterMs=\(Int(delay * 1000)) drawSeq=\(self.diagnosticDrawSeq) update=\(self.updateRangeDescription()) window=\(self.window != nil) bounds=\(Int(self.bounds.width))x\(Int(self.bounds.height))")
        }
    }

    private func updateRangeDescription() -> String {
        guard let range = getTerminal().getUpdateRange() else { return "nil" }
        return "\(range.startY)-\(range.endY)"
    }

    override func draw(_ dirtyRect: CGRect) {
        diagnosticDrawSeq += 1
        let shouldLog = CACurrentMediaTime() < diagnosticDrawLogUntil
        if shouldLog {
            DiagLog.log("terminal", "draw begin drawSeq=\(diagnosticDrawSeq) feedSeq=\(diagnosticLastFeedSeq) bytes=\(diagnosticLastFeedBytes) dirty=\(Int(dirtyRect.width))x\(Int(dirtyRect.height)) update=\(updateRangeDescription())")
        }
        super.draw(dirtyRect)
        if shouldLog {
            DiagLog.log("terminal", "draw end drawSeq=\(diagnosticDrawSeq) feedSeq=\(diagnosticLastFeedSeq) update=\(updateRangeDescription())")
        }
    }

    func snapToLiveTail(reason: String) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let targetY = max(0, contentSize.height - bounds.height)
        let oldY = contentOffset.y
        if abs(oldY - targetY) > 0.5 {
            setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
        }
        DiagLog.log("terminal", "tail snap reason=\(reason) offset=\(Int(oldY))->\(Int(contentOffset.y)) target=\(Int(targetY)) content=\(Int(contentSize.width))x\(Int(contentSize.height)) bounds=\(Int(bounds.width))x\(Int(bounds.height))")
    }

    func setFont(family: String, size: CGFloat) {
        let clamped = min(maxFontSize, max(minFontSize, size))
        currentSize = clamped
        let changed = family != fontFamily || abs(font.pointSize - clamped) > 0.1
        fontFamily = family
        if changed {
            font = TerminalFont.font(family: family, size: clamped)
        }
    }

    func setFontSize(_ size: CGFloat) { setFont(family: fontFamily, size: size) }

    func installZoomGestures() {
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        // SwiftTerm starts text selection on long-press but offers Copy through the
        // deprecated UIMenuController, which doesn't appear on iOS 16+. Add the
        // modern edit menu and present it on long-press so selected text is copyable.
        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        editMenu = menu
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(showEditMenu(_:))))
        installRemoteScrollGesture()
        installImageDrop()
    }

    func setRemoteScrollMode(_ active: Bool) {
        guard remoteScrollMode != active else { return }
        remoteScrollMode = active
        remoteScrollAccumulator = 0
        autoMuxScrollArmed = false
        installRemoteScrollGesture()

        if active {
            scrollEnabledBeforeRemoteScroll = isScrollEnabled
            isScrollEnabled = false
            _ = becomeFirstResponder()
        } else {
            isScrollEnabled = scrollEnabledBeforeRemoteScroll
        }
        onRemoteScrollModeChanged?(active)
    }

    private func installRemoteScrollGesture() {
        guard remoteScrollPanGesture == nil else { return }
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleRemoteScrollPan(_:)))
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        if #available(iOS 13.4, *) {
            gesture.allowedScrollTypesMask = [.continuous, .discrete]
        }
        addGestureRecognizer(gesture)
        remoteScrollPanGesture = gesture
    }

    @objc private func handleRemoteScrollPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            remoteScrollAccumulator = 0
            autoMuxScrollArmed = !remoteScrollMode && getTerminal().isCurrentBufferAlternate
            gesture.setTranslation(.zero, in: self)
        case .changed:
            let deltaY = gesture.translation(in: self).y
            gesture.setTranslation(.zero, in: self)
            if !remoteScrollMode {
                guard autoMuxScrollArmed, shouldEnterMuxScroll(deltaY: deltaY) else { return }
                enterMuxScrollModeFromGesture()
            }
            remoteScrollAccumulator += deltaY
            sendRemoteScrollSteps()
        case .ended, .cancelled, .failed:
            remoteScrollAccumulator = 0
            autoMuxScrollArmed = false
        default:
            break
        }
    }

    private func shouldEnterMuxScroll(deltaY: CGFloat) -> Bool {
        guard deltaY > 0, getTerminal().isCurrentBufferAlternate else { return false }
        let rows = max(1, getTerminal().rows)
        let lineHeight = max(12, bounds.height / CGFloat(rows))
        return deltaY >= min(18, lineHeight * 0.75)
    }

    private func enterMuxScrollModeFromGesture() {
        DiagLog.log("terminal", "auto mux scroll enter terminal=\(getTerminal().cols)x\(getTerminal().rows)")
        onSendBytes?([0x02, 0x5b])
        setRemoteScrollMode(true)
    }

    private func sendRemoteScrollSteps() {
        let rows = max(1, getTerminal().rows)
        let lineHeight = max(12, bounds.height / CGFloat(rows))
        let maxStepsPerEvent = 30
        var steps = Int(remoteScrollAccumulator / lineHeight)
        guard steps != 0 else { return }
        steps = min(maxStepsPerEvent, max(-maxStepsPerEvent, steps))
        remoteScrollAccumulator -= CGFloat(steps) * lineHeight

        let terminal = getTerminal()
        let up = terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
        let down = terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
        let sequence = steps > 0 ? up : down
        for _ in 0..<abs(steps) {
            onSendBytes?(sequence)
        }
    }

    /// Accept image drag-drops onto the terminal. Idempotent — only adds the
    /// interaction once even if setup runs again.
    private func installImageDrop() {
        guard !dropInteractionInstalled else { return }
        dropInteractionInstalled = true
        isUserInteractionEnabled = true
        addInteraction(UIDropInteraction(delegate: self))
    }

    @objc private func showEditMenu(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let editMenu else { return }
        let point = gesture.location(in: self)
        // Let SwiftTerm's own long-press set the selection first, then show Copy.
        DispatchQueue.main.async {
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.pinchZoom) else { return }
        switch gesture.state {
        case .began: pinchStart = currentSize
        case .changed, .ended:
            onZoomChange?(min(maxFontSize, max(minFontSize, pinchStart * gesture.scale)))
        default: break
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        let scroll = [
            UIKeyCommand(title: "Scroll Up", action: #selector(scrollPageUp), input: UIKeyCommand.inputUpArrow, modifierFlags: .command),
            UIKeyCommand(title: "Scroll Down", action: #selector(scrollPageDown), input: UIKeyCommand.inputDownArrow, modifierFlags: .command),
            UIKeyCommand(title: "Scroll to Top", action: #selector(scrollHome), input: UIKeyCommand.inputUpArrow, modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Scroll to Bottom", action: #selector(scrollEnd), input: UIKeyCommand.inputDownArrow, modifierFlags: [.command, .shift]),
            // Option(=Meta)+arrows send Page Up/Down to the remote — for tmux/less
            // scrollback, where local view-scroll can't reach the remote's history.
            UIKeyCommand(title: "Page Up", action: #selector(remotePageUp), input: UIKeyCommand.inputUpArrow, modifierFlags: .alternate),
            UIKeyCommand(title: "Page Down", action: #selector(remotePageDown), input: UIKeyCommand.inputDownArrow, modifierFlags: .alternate),
            UIKeyCommand(title: "Page Up", action: #selector(remotePageUp), input: UIKeyCommand.inputPageUp, modifierFlags: []),
            UIKeyCommand(title: "Page Down", action: #selector(remotePageDown), input: UIKeyCommand.inputPageDown, modifierFlags: []),
        ]
        scroll.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + [
            UIKeyCommand(title: "Zoom In", action: #selector(zoomIn), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "Zoom In", action: #selector(zoomIn), input: "+", modifierFlags: .command),
            UIKeyCommand(title: "Zoom Out", action: #selector(zoomOut), input: "-", modifierFlags: .command),
            UIKeyCommand(title: "Actual Size", action: #selector(zoomReset), input: "0", modifierFlags: .command),
        ] + scroll
    }

    private var scrollPage: Int { max(1, getTerminal().rows - 2) }
    @objc private func scrollPageUp() { scrollUp(lines: scrollPage) }
    @objc private func scrollPageDown() { scrollDown(lines: scrollPage) }
    // scrollUp/Down clamp to the buffer ends, so a large count = jump to top/bottom.
    @objc private func scrollHome() { scrollUp(lines: 1_000_000) }
    @objc private func scrollEnd() { scrollDown(lines: 1_000_000) }

    @objc private func remotePageUp() { onSendBytes?(EscapeSequences.cmdPageUp) }
    @objc private func remotePageDown() { onSendBytes?(EscapeSequences.cmdPageDown) }

    @objc private func zoomIn() { onZoomChange?(min(maxFontSize, currentSize + 1)) }
    @objc private func zoomOut() { onZoomChange?(max(minFontSize, currentSize - 1)) }
    @objc private func zoomReset() { onZoomChange?(defaultFontSize) }

    // MARK: Image paste (⌘V)

    /// Intercept ⌘V when the clipboard holds an image: upload it (consume the
    /// event). For text, defer to SwiftTerm's own paste so normal paste is intact.
    override func paste(_ sender: Any?) {
        if let (data, ext) = Self.imageFromPasteboard() {
            onImageDropped?(data, ext)
            return   // consume — don't fall through to text paste
        }
        super.paste(sender)
    }

    // Note: no canPerformAction override is needed — SwiftTerm's TerminalView
    // already returns true for paste(_:) unconditionally (it's `public override`,
    // not `open`, so it can't be overridden here anyway), so ⌘V / the Paste menu
    // item stays enabled even when the clipboard holds only an image.

    /// Pull image bytes off the general pasteboard, preferring native PNG/JPEG so
    /// we keep the original encoding; falls back to re-encoding a UIImage as PNG.
    static func imageFromPasteboard() -> (Data, String)? {
        let pb = UIPasteboard.general
        guard pb.hasImages else { return nil }
        if let png = pb.data(forPasteboardType: UTType.png.identifier) { return (png, "png") }
        if let jpeg = pb.data(forPasteboardType: UTType.jpeg.identifier) { return (jpeg, "jpg") }
        if let png = pb.image?.pngData() { return (png, "png") }
        return nil
    }
}

extension ZoomableTerminalView: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction,
                         sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let item = session.items.first else { return }
        let provider = item.itemProvider

        // Prefer the raw representation so we get the real PNG/JPEG bytes + a precise
        // ext from the UTI; fall back to re-encoding a loaded UIImage as PNG.
        let imageTypes = provider.registeredTypeIdentifiers.filter {
            UTType($0)?.conforms(to: .image) == true
        }
        if let typeID = imageTypes.first(where: { $0 == UTType.png.identifier })
            ?? imageTypes.first(where: { $0 == UTType.jpeg.identifier })
            ?? imageTypes.first {
            provider.loadDataRepresentation(forTypeIdentifier: typeID) { [weak self] data, _ in
                guard let self, let data else {
                    self?.dropFallbackToUIImage(provider)
                    return
                }
                let ext = (UTType(typeID)?.preferredFilenameExtension) ?? "png"
                DispatchQueue.main.async { self.onImageDropped?(data, ext) }
            }
        } else {
            dropFallbackToUIImage(provider)
        }
    }

    private func dropFallbackToUIImage(_ provider: NSItemProvider) {
        guard provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let self, let image = object as? UIImage, let data = image.pngData() else { return }
            DispatchQueue.main.async { self.onImageDropped?(data, "png") }
        }
    }
}

extension ZoomableTerminalView: UIEditMenuInteractionDelegate {
    // Show the system edit actions the terminal supports (Copy when a selection
    // is active, Paste, Select All — all routed through SwiftTerm's responder).
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: suggestedActions)
    }
}

/// Embeds a session's persistent `TerminalSurface.view`. The view is owned by
/// the surface cache, not this representable, so switching tabs re-embeds the
/// same view (buffer intact) rather than building a new one.
struct TerminalSurfaceView: UIViewRepresentable {
    let surface: TerminalSurface
    @Binding var fontSize: CGFloat
    let themeId: String
    let fontFamily: String
    let hardwareKeyboard: Bool
    /// Bundles cursor/meta prefs so a change re-triggers updateUIView → applyPrefs.
    let prefs: String
    @Binding var muxScrollActive: Bool

    func makeUIView(context: Context) -> ZoomableTerminalView {
        surface.onZoomChange = { fontSize = $0 }
        surface.view.onRemoteScrollModeChanged = { muxScrollActive = $0 }
        surface.apply(themeId: themeId, fontFamily: fontFamily, fontSize: fontSize, hardwareKeyboard: hardwareKeyboard)
        surface.refresh()   // re-embed after a tab switch: redraw the kept buffer
        return surface.view
    }

    func updateUIView(_ terminal: ZoomableTerminalView, context: Context) {
        surface.onZoomChange = { fontSize = $0 }
        surface.view.onRemoteScrollModeChanged = { muxScrollActive = $0 }
        surface.apply(themeId: themeId, fontFamily: fontFamily, fontSize: fontSize, hardwareKeyboard: hardwareKeyboard)
    }
}

extension ZoomableTerminalView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === remoteScrollPanGesture || otherGestureRecognizer === remoteScrollPanGesture
    }
}
