import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import SwiftTerm
import UniformTypeIdentifiers
import QuartzCore
import SafariServices
import BsnsSSHCore

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
    @AppStorage(SettingsKey.predictiveText) private var predictiveText = false
    @AppStorage(SettingsKey.keepAwake) private var keepAwake = false
    @AppStorage(SettingsKey.showKeyBar) private var showKeyBar = true
    @AppStorage(SettingsKey.tmuxScrollSequence) private var tmuxScrollSequence = "C-b ["
    @AppStorage(SettingsKey.screenScrollSequence) private var screenScrollSequence = "C-a ["
    @AppStorage(SettingsKey.multiplexer) private var multiplexer = MultiplexerPref.both.rawValue
    @AppStorage(SettingsKey.scrollGesture) private var scrollGesture = ScrollGesturePref.automatic.rawValue

    @State private var scrolledBack = false
    @State private var pendingPaste: PendingPaste?
    @State private var tmuxPanel: TmuxPanelView.Tab?
    @State private var forwarding = false
    @State private var forwardError: String?
    @State private var browsing: BrowserPage?
    @State private var hwKeyboard = HardwareKeyboardMonitor()
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var showForwards = false
    @State private var showSnippets = false
    @State private var showHistory = false
    @State private var showHelp = false
    @State private var muxScrollActive = false
    @State private var tappedLink: URL?
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
                                suppressAccessory: hwKeyboard.isConnected || showKeyBar,
                                tmuxSequence: tmuxScrollSequence,
                                screenSequence: screenScrollSequence,
                                prefs: "\(cursorStyle)\(cursorBlink)\(optionAsMeta)\(predictiveText)\(scrollGesture)",
                                muxScrollActive: $muxScrollActive,
                                scrolledBack: $scrolledBack,
                                tappedLink: $tappedLink,
                                pendingPaste: $pendingPaste)
                .overlay(alignment: .top) { transferBanner }
                .overlay(alignment: .bottomTrailing) { jumpToLatestButton }
            // The shortcut bar stays put whether the soft keyboard is up or down
            // (it replaces the keyboard's built-in accessory row, which is
            // suppressed while the bar is on). With a physical keyboard it
            // collapses to Esc plus multiplexer scroll mode.
            if showKeyBar {
                Divider().overlay(Color(theme.ansi[8].uiColor).opacity(0.5))
                TerminalKeyBar(session: session, handle: handle, theme: theme,
                               tmuxSequence: tmuxScrollSequence,
                               screenSequence: screenScrollSequence,
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
            .sheet(isPresented: $showForwards) { PortForwardsView(session: session) }
            .sheet(isPresented: $showSnippets) {
                SnippetPicker { snip in session.runCommand(snip.command) }
            }
            .sheet(isPresented: $showHistory) {
                CommandHistoryPicker { cmd in session.runCommand(cmd) }
            }
            .sheet(isPresented: $showHelp) {
                NavigationStack { TerminalHelpView(showsDoneButton: true) }
            }
            .sheet(item: $tmuxPanel) { tab in TmuxPanelView(session: session, tab: tab) }
            .sheet(item: $browsing) { page in
                BrowserSheet(url: page.url).ignoresSafeArea()
            }
            .confirmationDialog(tappedLink?.absoluteString ?? "",
                                isPresented: Binding(get: { tappedLink != nil },
                                                     set: { if !$0 { tappedLink = nil } }),
                                titleVisibility: .visible) {
                // The title is the full URL on purpose: this text came from the
                // remote, and the destination is the one thing worth reading
                // before handing the tap to Safari.
                if let url = tappedLink {
                    if let loopback = LoopbackURL(url) {
                        // "localhost" printed by the server means the SERVER's
                        // loopback. Safari would look on this device instead, so
                        // the useful action is to forward the port and open that.
                        Button("Forward Port \(String(loopback.remotePort)) and Open") { openForwarded(loopback) }
                    } else {
                        Button("Open in Safari") { UIApplication.shared.open(url) }
                    }
                    Button("Copy Link") { UIPasteboard.general.string = url.absoluteString }
                }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Couldn't forward the port", isPresented: Binding(get: { forwardError != nil },
                                                                    set: { if !$0 { forwardError = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(forwardError ?? "")
            }
            .alert(pendingPaste.map { "Paste \($0.lineCount) lines?" } ?? "",
                   isPresented: Binding(get: { pendingPaste != nil }, set: { if !$0 { pendingPaste = nil } }),
                   presenting: pendingPaste) { paste in
                Button("Paste") { paste.proceed() }
                Button("Cancel", role: .cancel) { }
            } message: { paste in
                Text("If the program isn't taking pastes as a block, each line runs as soon as it arrives.\n\n\(paste.preview)")
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
            Button { predictiveText.toggle() } label: {
                Image(systemName: "textformat.abc")
                    .foregroundStyle(predictiveText ? Brand.accent : Color.primary)
            }
            .accessibilityLabel(predictiveText ? "Predictive text on" : "Predictive text off")
            .accessibilityHint("Toggles predictive text")
            muxScrollButtons
            Button { setZoom(CGFloat(fontSize) - 1) } label: { Image(systemName: "textformat.size.smaller") }
                .accessibilityLabel("Decrease text size")
            Button { setZoom(CGFloat(fontSize) + 1) } label: { Image(systemName: "textformat.size.larger") }
                .accessibilityLabel("Increase text size")
            settingsMenu
        }
        .labelStyle(.iconOnly)
    }

    /// Only surface the buttons for the multiplexer(s) that apply here — an
    /// app-launched tmux session shows tmux only; otherwise the user's preference.
    private var muxButtons: (tmux: Bool, screen: Bool) {
        (MultiplexerPref(rawValue: multiplexer) ?? .both)
            .buttons(tmuxKnown: session.spec.tmuxSession != nil)
    }

    @ViewBuilder private var muxScrollButtons: some View {
        if muxScrollActive {
            Button { finishMuxScroll() } label: { muxScrollLabel("done", active: true) }
                .accessibilityLabel("Exit multiplexer scroll mode")
        } else {
            if muxButtons.tmux {
                // Window switching without leaving the keyboard: the arrows step
                // through tmux's windows, and a long press on "tmux" has the rest.
                Button { sendTmuxKey("p") } label: { Image(systemName: "chevron.left").frame(minWidth: 22, minHeight: 28) }
                    .accessibilityLabel("Previous tmux window")
                Menu {
                    Button { sendTmuxKey("n") } label: { Label("Next Window", systemImage: "chevron.right") }
                    Button { sendTmuxKey("p") } label: { Label("Previous Window", systemImage: "chevron.left") }
                    Button { sendTmuxKey("l") } label: { Label("Last Window", systemImage: "arrow.uturn.backward") }
                    Button { sendTmuxKey("c") } label: { Label("New Window", systemImage: "plus") }
                    if session.spec.jump == nil {
                        Divider()
                        Button { tmuxPanel = .windows } label: { Label("All Windows…", systemImage: "rectangle.stack") }
                        Button { tmuxPanel = .history } label: { Label("History…", systemImage: "text.justify.left") }
                    }
                } label: {
                    muxScrollLabel("tmux", active: false)
                } primaryAction: {
                    startMuxScroll(sequence: tmuxScrollSequence, fallback: [0x02, 0x5b])
                }
                .accessibilityLabel("Enter tmux scroll mode")
                .accessibilityHint("Touch and hold for window commands")
                Button { sendTmuxKey("n") } label: { Image(systemName: "chevron.right").frame(minWidth: 22, minHeight: 28) }
                    .accessibilityLabel("Next tmux window")
            }
            if muxButtons.screen {
                Button { startMuxScroll(sequence: screenScrollSequence, fallback: [0x01, 0x5b]) } label: { muxScrollLabel("screen", active: false) }
                    .accessibilityLabel("Enter screen scroll mode")
            }
        }
    }

    private func muxScrollLabel(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(active ? Brand.accent : Color.primary)
            .frame(minWidth: text.count > 4 ? 52 : 38, minHeight: 28)
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
                Image(systemName: session.transferSymbol).foregroundStyle(Brand.accent)
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

    /// Shown while the terminal is scrolled back into this device's scrollback:
    /// the view holds its place there while output keeps arriving, so there has
    /// to be an obvious way back to it.
    @ViewBuilder private var jumpToLatestButton: some View {
        if scrolledBack {
            Button { handle.scrollToLatest() } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(.bar, in: Circle())
                    .overlay(Circle().strokeBorder(.separator))
            }
            .padding(12)
            .shadow(radius: 4, y: 1)
            .accessibilityLabel("Jump to latest output")
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

    /// Forward the server-side port a link points at, then show it in an in-app
    /// browser sheet. In-app on purpose: the forward lives in this process, and
    /// switching to Safari would background the app and suspend the tunnel
    /// before the page finished loading.
    private func openForwarded(_ loopback: LoopbackURL) {
        guard !forwarding else { return }
        forwarding = true
        Task {
            switch await session.forwardLoopback(loopback) {
            case .success(let url): browsing = BrowserPage(url: url)
            case .failure(let failure): forwardError = failure.message
            }
            forwarding = false
        }
    }

    /// Send a tmux command key after the prefix. The prefix is the one already
    /// configured for scroll mode ("C-b [" → C-b), so a remapped prefix carries over.
    private func sendTmuxKey(_ key: String) {
        let prefix = KeyBarPresets.tmuxPrefix(fromScrollSequence: tmuxScrollSequence)
        let bytes = KeySequence.bytes(for: "\(prefix) \(key)", fallback: [0x02] + Array(key.utf8))
        session.write(bytes[...])
    }

    private func startMuxScroll(sequence: String, fallback: [UInt8]) {
        let bytes = KeySequence.bytes(for: sequence, fallback: fallback)
        session.write(bytes[...])
        muxScrollActive = true
        handle.setRemoteScrollMode(true)
    }

    private func finishMuxScroll() {
        muxScrollActive = false
        handle.setRemoteScrollMode(false)
        session.write([UInt8(0x1b)][...])
    }

    private var settingsMenu: some View {
        Menu {
            Button { handle.paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            Button { handle.selectAll() } label: { Label("Select All", systemImage: "selection.pin.in.out") }

            // tmux beside the terminal (over a second SSH connection). Not through
            // a jump host: that connection has no tunnel to ride.
            if muxButtons.tmux, session.spec.jump == nil {
                Section("tmux") {
                    Button { tmuxPanel = .windows } label: { Label("Windows…", systemImage: "rectangle.stack") }
                    Button { tmuxPanel = .history } label: { Label("History…", systemImage: "text.justify.left") }
                }
            }
            if handle.hasPromptMarks {
                Section("Prompts") {
                    Button { handle.jumpToPrompt(previous: true) } label: { Label("Previous Prompt", systemImage: "chevron.up") }
                    Button { handle.jumpToPrompt(previous: false) } label: { Label("Next Prompt", systemImage: "chevron.down") }
                    Button { copyLastCommandOutput() } label: { Label("Copy Last Output", systemImage: "doc.on.doc") }
                }
            }

            let count = session.forwards.count
            Button { showForwards = true } label: {
                Label(count == 0 ? "Port Forwarding…" : "Port Forwarding (\(count))…",
                      systemImage: "arrow.left.arrow.right")
            }
            Button { showSnippets = true } label: { Label("Run a snippet…", systemImage: "text.badge.plus") }
            Button { showHistory = true } label: { Label("Command history…", systemImage: "clock.arrow.circlepath") }
            Button { showHelp = true } label: { Label("Terminal Help…", systemImage: "questionmark.circle") }
            Toggle(isOn: $predictiveText) {
                Label("Predictive text", systemImage: "textformat.abc")
            }
            Toggle(isOn: Binding(get: { handle.mouseReporting }, set: { handle.mouseReporting = $0 })) {
                Label("Send taps and swipes to the remote", systemImage: "hand.tap")
            }

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

    private func copyLastCommandOutput() {
        guard let output = handle.lastCommandOutput(), !output.isEmpty else {
            session.flash("No command output to copy", symbol: "exclamationmark.triangle")
            return
        }
        UIPasteboard.general.string = output
        let lines = output.split(whereSeparator: \.isNewline).count
        session.flash("Copied \(lines) line\(lines == 1 ? "" : "s") of output", symbol: "doc.on.doc")
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

/// A multi-line paste waiting for the user's go-ahead.
struct PendingPaste: Identifiable {
    let id = UUID()
    let lineCount: Int
    let preview: String
    let proceed: () -> Void
}

/// A forwarded page being shown in the in-app browser sheet.
struct BrowserPage: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system's in-app browser. It runs the page in the browser's own process,
/// not this app's — the app itself still opens no connections beyond SSH.
struct BrowserSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
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
    func scrollToLatest() { terminal?.scrollToLiveTail(animated: true) }

    /// Whether taps and swipes may be reported to a remote that asked for the mouse.
    var mouseReporting = true {
        didSet { terminal?.allowMouseReporting = mouseReporting }
    }

    /// Whether the shell has marked any prompts (OSC 133). Kept here, updated
    /// after each feed, so the menu can show its prompt actions only when they
    /// would do something.
    private(set) var hasPromptMarks = false
    func notePromptMarks() {
        let marked = terminal?.getTerminal().hasPromptMarks ?? false
        if marked != hasPromptMarks { hasPromptMarks = marked }
    }
    func jumpToPrompt(previous: Bool) { terminal?.scrollToPrompt(previous: previous) }
    func lastCommandOutput() -> String? { terminal?.getTerminal().lastCommandOutput() }
    func setRemoteScrollMode(_ active: Bool) { (terminal as? ZoomableTerminalView)?.setRemoteScrollMode(active) }
    func sendRemoteScrollPage(up: Bool) { (terminal as? ZoomableTerminalView)?.sendRemoteScrollPage(up: up) }

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
    /// Called when the cached terminal view is attached to a visible window.
    var onBecameVisible: (() -> Void)?
    /// Keeps SwiftUI controls in sync when a gesture enters multiplexer scroll mode.
    var onRemoteScrollModeChanged: ((Bool) -> Void)?
    /// An image was dropped or pasted onto the terminal — (PNG/JPEG data, ext).
    /// Set by the surface → session.uploadImage.
    var onImageDropped: ((Data, String) -> Void)?
    /// A paste that should be confirmed first. The receiver shows the prompt and
    /// calls `proceed` if the user agrees.
    var onConfirmPaste: ((PendingPaste) -> Void)?
    var tmuxScrollSequence = "C-b ["
    var screenScrollSequence = "C-a ["
    /// What a scroll gesture moves — see `ScrollGesturePref`.
    var scrollGesture: ScrollGesturePref = .automatic {
        didSet { if scrollGesture != oldValue { applyScrollRoute() } }
    }
    private var dropInteractionInstalled = false
    private var remoteScrollPanGesture: UIPanGestureRecognizer?
    private var remoteScrollMode = false
    private var remoteScrollAccumulator: CGFloat = 0
    private var autoMuxScrollArmed = false
    /// Where a one-finger scroll goes.
    private enum ScrollRoute {
        case local   // this device's scrollback
        case wheel   // mouse-wheel events to a remote that asked for the mouse
        case keys    // navigation keys, in multiplexer scroll mode
    }
    /// The route the pan in progress was started on.
    private var panRoute: ScrollRoute = .local
    // A flick keeps scrolling the remote after the finger lifts, decaying the
    // way a scroll view does, until it runs out or the screen is touched again.
    private var momentumLink: CADisplayLink?
    private var momentumVelocity: CGFloat = 0     // points per second, + = finger moving down
    /// Where the swipe in progress started, relative to the visible screen. Every
    /// wheel event of that swipe (and of the glide after it) is reported there.
    private var wheelAnchor: CGPoint = .zero
    private var touchDownGesture: TouchDownRecognizer?
    private var lastLoggedMouseReporting = false
    /// Below this a lift is a stop, not a flick.
    private static let momentumMinVelocity: CGFloat = 250
    /// A scroll view's own deceleration: the velocity kept after each millisecond.
    private static let momentumDecayPerMs: CGFloat = 0.998
    /// Finger travel per wheel event, in rows. A wheel notch moves most
    /// programs about three lines (a multiplexer's copy mode, five), so one
    /// event per three rows of travel keeps the content roughly under the
    /// finger — exactly so for a three-line program, a little ahead of it in
    /// copy mode.
    private static let wheelRowsPerEvent: CGFloat = 3
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
        guard window != nil else {
            stopMomentum()   // the display link retains this view until invalidated
            return
        }
        onBecameVisible?()
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

    /// Fires after a feed if no `draw(_:)` has happened since — the incremental
    /// dirty-region path stalled. Seen after a long background: SwiftTerm feeds the
    /// new output into the buffer and calls `setNeedsDisplay`, but UIKit never
    /// services it, so typed characters reach the server (and tmux) yet never paint
    /// locally. Recover by forcing a full repaint — the same hammer the resume path
    /// uses — instead of merely logging the stall. Bounded: only the two watches per
    /// feed can heal, and a heal that does draw bumps `diagnosticDrawSeq` so the
    /// later watch no-ops.
    private func scheduleDrawWatch(feedSeq: Int, bytes: Int, drawCountAtFeed: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.diagnosticLastFeedSeq == feedSeq,
                  self.diagnosticDrawSeq == drawCountAtFeed else { return }
            let drawable = self.window != nil && self.bounds.width > 1 && self.bounds.height > 1
            DiagLog.log("terminal", "draw pending feedSeq=\(feedSeq) bytes=\(bytes) afterMs=\(Int(delay * 1000)) drawSeq=\(self.diagnosticDrawSeq) update=\(self.updateRangeDescription()) window=\(self.window != nil) bounds=\(Int(self.bounds.width))x\(Int(self.bounds.height)) heal=\(drawable)")
            // No draw serviced the feed: force the whole buffer dirty and re-request
            // a paint. Leaves scroll position untouched (don't yank a user reading
            // scrollback to the tail) — only the resume path snaps to live.
            guard drawable else { return }
            self.getTerminal().updateFullScreen()
            self.setNeedsDisplay(self.bounds)
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
        // Reading scrollback is not a layout glitch to repair: leave the view
        // where the user put it.
        guard followsLiveTail else { return }
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
        // Selection is handled by the terminal's own long-press (press selects a
        // word, drag extends, lift asks for a menu). Present the MODERN edit menu
        // when it asks — the built-in fallback is the deprecated UIMenuController,
        // which never appears on iOS 16+. A second app-level long-press recognizer
        // used to race the terminal's own and made selection feel coin-flip.
        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        editMenu = menu
        selectionMenuRequested = { [weak self] region in
            guard let self, let editMenu = self.editMenu else { return }
            // Region is in this view's (content) coordinate space; aim the menu
            // at the top edge of the selection.
            let point = CGPoint(x: region.midX, y: region.minY)
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        }
        installRemoteScrollGesture()
        installImageDrop()
    }

    func setRemoteScrollMode(_ active: Bool) {
        guard remoteScrollMode != active else { return }
        remoteScrollMode = active
        remoteScrollAccumulator = 0
        autoMuxScrollArmed = false
        installRemoteScrollGesture()
        applyScrollRoute()
        if active { _ = becomeFirstResponder() }
        onRemoteScrollModeChanged?(active)
    }

    /// Where a one-finger scroll goes right now.
    ///
    /// A remote that has asked for mouse events (a multiplexer in mouse mode, a
    /// full-screen program) keeps its own history, and often it is the only
    /// complete one: mosh syncs the visible screen, not the stream, so output
    /// that passed between two frames never reaches this device. Wheel events
    /// let that program scroll itself — the same thing a desktop terminal's
    /// scroll wheel does. Everything else scrolls this device's own scrollback.
    ///
    /// The "in-app" preference only changes the answer where there is a local
    /// scrollback to prefer: the alternate screen (a full-screen program over
    /// plain SSH) saves none, so there the swipe goes to the program regardless.
    private func scrollRoute(for terminal: Terminal) -> ScrollRoute {
        if remoteScrollMode { return .keys }
        let remoteWantsMouse = allowMouseReporting && terminal.mouseMode != .off
        if remoteWantsMouse, scrollGesture == .automatic || terminal.isCurrentBufferAlternate { return .wheel }
        return .local
    }

    /// Point the scroll view's own pan at the right job for the current route.
    /// The local scrollback stays reachable on every route but `keys`: when one
    /// finger belongs to the remote, two fingers scroll locally.
    private func applyScrollRoute() { applyScrollRoute(for: getTerminal()) }

    private func applyScrollRoute(for terminal: Terminal) {
        let pan = panGestureRecognizer
        switch scrollRoute(for: terminal) {
        case .local:
            isScrollEnabled = true
            pan.minimumNumberOfTouches = 1
            pan.allowedScrollTypesMask = .all
        case .wheel:
            isScrollEnabled = true
            pan.minimumNumberOfTouches = 2
            pan.allowedScrollTypesMask = []   // a trackpad scroll is a wheel, too
        case .keys:
            isScrollEnabled = false
        }
    }

    /// The remote turned mouse reporting on or off. Upstream answers by turning
    /// every finger drag into a held-button drag for the remote — which starts a
    /// selection there, when what a drag on a touch screen means is "scroll" —
    /// and that recognizer raced the scroll view's own pan, so the same swipe
    /// did one or the other at random. Finger drags are routed here instead
    /// (taps still reach the remote as clicks).
    override func mouseModeChanged(source: Terminal) {
        // `source`, not `getTerminal()`: the emulator reports its initial mode
        // while it is still being constructed, before the view holds it.
        let reporting = source.mouseMode != .off
        if reporting != lastLoggedMouseReporting {
            lastLoggedMouseReporting = reporting
            DiagLog.log("terminal", "mouse reporting \(reporting ? "on" : "off") (\(source.mouseMode))")
        }
        applyScrollRoute(for: source)
    }

    private func installRemoteScrollGesture() {
        guard remoteScrollPanGesture == nil else { return }
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleRemoteScrollPan(_:)))
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        // One finger only: two fingers are the local-scrollback gesture and the
        // pinch, neither of which should also drive the remote.
        gesture.maximumNumberOfTouches = 1
        if #available(iOS 13.4, *) {
            gesture.allowedScrollTypesMask = [.continuous, .discrete]
        }
        addGestureRecognizer(gesture)
        remoteScrollPanGesture = gesture

        // A finger landing anywhere stops a glide at once, as it does in any
        // scroll view — without waiting for a pan to be recognised.
        let touchDown = TouchDownRecognizer { [weak self] in self?.stopMomentum() }
        touchDown.cancelsTouchesInView = false
        touchDown.delaysTouchesBegan = false
        touchDown.delegate = self
        addGestureRecognizer(touchDown)
        touchDownGesture = touchDown
    }

    @objc private func handleRemoteScrollPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopMomentum()
            remoteScrollAccumulator = 0
            DiagLog.log("terminal", "scroll pan began mouse=\(getTerminal().mouseMode != .off) alt=\(getTerminal().isCurrentBufferAlternate)")
            // Re-read the route: the keyboard accessory can switch mouse
            // reporting off without telling anyone.
            applyScrollRoute()
            panRoute = scrollRoute(for: getTerminal())
            autoMuxScrollArmed = panRoute == .local && getTerminal().isCurrentBufferAlternate
            // The remote scrolls relative to its live screen, so show that.
            if panRoute == .wheel, !isAtLiveTail { scrollToLiveTail() }
            let touch = gesture.location(in: self)
            wheelAnchor = CGPoint(x: touch.x, y: touch.y - contentOffset.y)
            gesture.setTranslation(.zero, in: self)
        case .changed:
            let deltaY = gesture.translation(in: self).y
            gesture.setTranslation(.zero, in: self)
            switch panRoute {
            case .wheel:
                remoteScrollAccumulator += deltaY
                sendWheelSteps()
            case .keys:
                remoteScrollAccumulator += deltaY
                sendRemoteScrollSteps()
            case .local:
                guard autoMuxScrollArmed, shouldEnterMuxScroll(deltaY: deltaY) else { return }
                enterMuxScrollModeFromGesture()
                panRoute = .keys
                remoteScrollAccumulator += deltaY
                sendRemoteScrollSteps()
            }
        case .ended:
            autoMuxScrollArmed = false
            if panRoute == .wheel {
                DiagLog.log("terminal", "wheel pan ended velocity=\(Int(gesture.velocity(in: self).y))")
                startMomentum(velocity: gesture.velocity(in: self).y)
            } else {
                remoteScrollAccumulator = 0
            }
        case .cancelled, .failed:
            remoteScrollAccumulator = 0
            autoMuxScrollArmed = false
        default:
            break
        }
    }

    private func startMomentum(velocity: CGFloat) {
        stopMomentum()
        guard abs(velocity) >= Self.momentumMinVelocity else {
            remoteScrollAccumulator = 0
            return
        }
        momentumVelocity = velocity
        let link = CADisplayLink(target: self, selector: #selector(momentumTick(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    /// Any new touch, a route change, or leaving the screen ends the glide.
    private func stopMomentum() {
        guard let link = momentumLink else { return }
        link.invalidate()
        momentumLink = nil
        momentumVelocity = 0
        remoteScrollAccumulator = 0
    }

    @objc private func momentumTick(_ link: CADisplayLink) {
        // The remote may have dropped mouse mode mid-glide (the program exited).
        guard window != nil, scrollRoute(for: getTerminal()) == .wheel else {
            stopMomentum()
            return
        }
        let dt = CGFloat(min(0.05, max(0, link.targetTimestamp - link.timestamp)))
        remoteScrollAccumulator += momentumVelocity * dt
        sendWheelSteps()
        momentumVelocity *= pow(Self.momentumDecayPerMs, dt * 1000)
        if abs(momentumVelocity) < 40 { stopMomentum() }
    }

    /// Turn accumulated finger travel into wheel events.
    ///
    /// Programs route the wheel by position — a multiplexer scrolls the pane
    /// under it — so the position matters, and it must be the place the swipe
    /// STARTED, not where the finger is now. A mouse pointer sits still while
    /// its wheel turns; a finger scrolling back travels down the screen and
    /// ends on the bottom row, which in a multiplexer is the status line, where
    /// the wheel means "switch window". For the same reason the row is kept off
    /// the first and last lines of the screen: a swipe that starts on a status
    /// line is still someone trying to scroll.
    private func sendWheelSteps() {
        let terminal = getTerminal()
        let rows = max(1, terminal.rows)
        let cols = max(1, terminal.cols)
        let rowHeight = max(12, bounds.height / CGFloat(rows))
        let stepHeight = rowHeight * Self.wheelRowsPerEvent
        var steps = Int(remoteScrollAccumulator / stepHeight)
        guard steps != 0 else { return }
        steps = min(12, max(-12, steps))
        remoteScrollAccumulator -= CGFloat(steps) * stepHeight

        // The remote wants a cell on its screen. Capped at 222 — the legacy one-byte mouse
        // encoding cannot express a larger coordinate.
        let col = min(222, min(cols - 1, max(0, Int(wheelAnchor.x / max(1, bounds.width / CGFloat(cols))))))
        let touched = Int(wheelAnchor.y / rowHeight)
        let row = min(222, rows > 2 ? min(rows - 2, max(1, touched)) : min(rows - 1, max(0, touched)))
        // Finger down = content down = earlier output = wheel up.
        let flags = terminal.encodeButton(button: steps > 0 ? 4 : 5, release: false,
                                          shift: false, meta: false, control: false)
        for _ in 0..<abs(steps) {
            terminal.sendEvent(buttonFlags: flags, x: col, y: row)
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
        onSendBytes?(KeySequence.bytes(for: tmuxScrollSequence, fallback: [0x02, 0x5b]))
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

        sendRemoteScrollRows(steps)
    }

    func sendRemoteScrollPage(up: Bool) {
        let lines = max(1, getTerminal().rows - 2)
        sendRemoteScrollRows(up ? lines : -lines)
    }

    private func sendRemoteScrollRows(_ rows: Int) {
        guard rows != 0 else { return }
        let terminal = getTerminal()
        let up = terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
        let down = terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
        let sequence = rows > 0 ? up : down
        for _ in 0..<abs(rows) {
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
        let toggleMuxScroll = UIKeyCommand(title: "Toggle tmux Scroll Mode",
                                           action: #selector(toggleMuxScrollMode),
                                           input: "s",
                                           modifierFlags: [.command, .alternate])
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
        toggleMuxScroll.wantsPriorityOverSystemBehavior = true
        scroll.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + [
            UIKeyCommand(title: "Zoom In", action: #selector(zoomIn), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "Zoom In", action: #selector(zoomIn), input: "+", modifierFlags: .command),
            UIKeyCommand(title: "Zoom Out", action: #selector(zoomOut), input: "-", modifierFlags: .command),
            UIKeyCommand(title: "Actual Size", action: #selector(zoomReset), input: "0", modifierFlags: .command),
        ] + [toggleMuxScroll] + scroll
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard remoteScrollMode else {
            super.pressesBegan(presses, with: event)
            return
        }

        var passthrough = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                passthrough.insert(press)
                continue
            }
            let modified = key.modifierFlags.contains(.command)
                || key.modifierFlags.contains(.alternate)
                || key.modifierFlags.contains(.control)
                || key.modifierFlags.contains(.shift)
            if !modified, key.keyCode == .keyboardPageUp {
                sendRemoteScrollPage(up: true)
            } else if !modified, key.keyCode == .keyboardPageDown {
                sendRemoteScrollPage(up: false)
            } else {
                passthrough.insert(press)
            }
        }
        if !passthrough.isEmpty {
            super.pressesBegan(passthrough, with: event)
        }
    }

    private var scrollPage: Int { max(1, getTerminal().rows - 2) }
    @objc private func scrollPageUp() { scrollUp(lines: scrollPage) }
    @objc private func scrollPageDown() { scrollDown(lines: scrollPage) }
    // scrollUp/Down clamp to the buffer ends, so a large count = jump to top/bottom.
    @objc private func scrollHome() { scrollUp(lines: 1_000_000) }
    @objc private func scrollEnd() { scrollDown(lines: 1_000_000) }

    @objc private func remotePageUp() {
        remoteScrollMode ? sendRemoteScrollPage(up: true) : onSendBytes?(EscapeSequences.cmdPageUp)
    }
    @objc private func remotePageDown() {
        remoteScrollMode ? sendRemoteScrollPage(up: false) : onSendBytes?(EscapeSequences.cmdPageDown)
    }

    @objc private func toggleMuxScrollMode() {
        if remoteScrollMode {
            setRemoteScrollMode(false)
            onSendBytes?([0x1b])
        } else {
            onSendBytes?(KeySequence.bytes(for: tmuxScrollSequence, fallback: [0x02, 0x5b]))
            setRemoteScrollMode(true)
        }
    }

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
        // Several lines into a program that isn't taking pastes as a block: each
        // line break would run as Enter the moment it lands. Ask first.
        let policy = PasteGuard.Policy(rawValue: UserDefaults.standard.string(forKey: SettingsKey.confirmPaste) ?? "")
            ?? .whenRisky
        if policy != .never, let confirm = onConfirmPaste, let text = UIPasteboard.general.string,
           PasteGuard.needsConfirmation(text, bracketedPaste: getTerminal().bracketedPasteMode, policy: policy) {
            confirm(PendingPaste(lineCount: PasteGuard.lineCount(text), preview: PasteGuard.preview(text)) { [weak self] in
                self?.pasteText()
            })
            return
        }
        pasteText()
    }

    private func pasteText() { super.paste(nil) }

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
    /// Hide the keyboard's built-in accessory row: a hardware keyboard is
    /// attached, or the app's own shortcut bar is standing in for it.
    let suppressAccessory: Bool
    let tmuxSequence: String
    let screenSequence: String
    /// Bundles cursor/meta prefs so a change re-triggers updateUIView → applyPrefs.
    let prefs: String
    @Binding var muxScrollActive: Bool
    @Binding var scrolledBack: Bool
    @Binding var tappedLink: URL?
    @Binding var pendingPaste: PendingPaste?

    func makeUIView(context: Context) -> ZoomableTerminalView {
        surface.onZoomChange = { fontSize = $0 }
        surface.onLinkTapped = { tappedLink = $0 }
        surface.view.onRemoteScrollModeChanged = { muxScrollActive = $0 }
        surface.view.liveTailChanged = { scrolledBack = !$0 }
        surface.view.onConfirmPaste = { pendingPaste = $0 }
        // A cached surface comes back wherever it was left; the button has to
        // match it (deferred — this runs inside a view update).
        let following = surface.view.followsLiveTail
        DispatchQueue.main.async { scrolledBack = !following }
        surface.view.tmuxScrollSequence = tmuxSequence
        surface.view.screenScrollSequence = screenSequence
        surface.apply(themeId: themeId, fontFamily: fontFamily, fontSize: fontSize, suppressAccessory: suppressAccessory)
        surface.refresh()   // re-embed after a tab switch: redraw the kept buffer
        return surface.view
    }

    func updateUIView(_ terminal: ZoomableTerminalView, context: Context) {
        surface.onZoomChange = { fontSize = $0 }
        surface.onLinkTapped = { tappedLink = $0 }
        surface.view.onRemoteScrollModeChanged = { muxScrollActive = $0 }
        surface.view.liveTailChanged = { scrolledBack = !$0 }
        surface.view.onConfirmPaste = { pendingPaste = $0 }
        terminal.tmuxScrollSequence = tmuxSequence
        terminal.screenScrollSequence = screenSequence
        surface.apply(themeId: themeId, fontFamily: fontFamily, fontSize: fontSize, suppressAccessory: suppressAccessory)
    }
}

/// Reports a finger touching down and then gets out of the way: it never
/// recognises, so it can't delay or cancel any other gesture.
final class TouchDownRecognizer: UIGestureRecognizer {
    private let onTouchDown: () -> Void

    init(onTouchDown: @escaping () -> Void) {
        self.onTouchDown = onTouchDown
        super.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchDown()
        state = .failed
    }
}

extension ZoomableTerminalView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The touch-down observer never competes with anything.
        if gestureRecognizer === touchDownGesture || otherGestureRecognizer === touchDownGesture { return true }
        guard gestureRecognizer === remoteScrollPanGesture || otherGestureRecognizer === remoteScrollPanGesture
        else { return false }
        // Not alongside a long-press: that is a selection being dragged out, and
        // scrolling the remote underneath it (or dropping into multiplexer scroll
        // mode) is how a selection used to get destroyed mid-drag.
        return !(gestureRecognizer is UILongPressGestureRecognizer
                 || otherGestureRecognizer is UILongPressGestureRecognizer)
    }
}
