import SwiftUI
import AppKit
import SwiftTerm
import BsnsSSHCore

/// A live session: its terminal, and a banner when the connection is down.
struct MacTerminalScreen: View {
    let session: TerminalSession
    @Environment(MacSurfaceCache.self) private var surfaces
    @AppStorage(SettingsKey.theme) private var themeId = TerminalTheme.bsnsDark.id
    @AppStorage(SettingsKey.fontFamily) private var fontFamily = TerminalFont.families[0]
    @AppStorage(SettingsKey.fontSize) private var fontSize = 13.0

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            MacTerminalHost(surface: surfaces.surface(for: session),
                            themeId: themeId, fontFamily: fontFamily, fontSize: fontSize)
        }
        .navigationTitle(session.title)
    }

    @ViewBuilder private var statusBanner: some View {
        switch session.status {
        case .connected:
            EmptyView()
        case .connecting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reconnecting…")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
        case .disconnected(let reason):
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.orange)
                Text(reason.map { "Disconnected — \($0)" } ?? "Disconnected").lineLimit(2)
                Spacer()
                Button("Reconnect") { session.reconnect() }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
        }
    }
}

/// The AppKit terminal for one session, kept for the session's life so that
/// selecting another row and coming back shows the same buffer and scrollback.
@MainActor
final class MacTerminalSurface: NSObject, @preconcurrency TerminalViewDelegate {
    let session: TerminalSession
    let view: TerminalView

    private var appliedTheme: String?
    private var pendingFeed: [UInt8] = []
    private var flushScheduled = false
    private var lastSent: (cols: Int, rows: Int) = (-1, -1)
    private var pendingResize: DispatchWorkItem?

    /// Enough for a URL, a token, or a config block; small enough that a runaway
    /// or hostile remote can't stuff the pasteboard with megabytes.
    private static let maxRemoteClipboardBytes = 64 * 1024

    init(session: TerminalSession) {
        self.session = session
        self.view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        super.init()
        view.terminalDelegate = self
        let scrollback = UserDefaults.standard.integer(forKey: SettingsKey.scrollback)
        if scrollback > 0 { view.getTerminal().changeScrollback(scrollback) }

        // Output arrives off the main thread in bursts; gather what lands within
        // one turn of the run loop and feed it once.
        session.onOutput = { [weak self] bytes in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingFeed.append(contentsOf: bytes)
                self.scheduleFlush()
            }
        }
        session.refreshDisplay()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard !self.pendingFeed.isEmpty else { return }
            let chunk = self.pendingFeed
            self.pendingFeed.removeAll(keepingCapacity: true)
            self.view.feed(byteArray: chunk[...])
        }
    }

    func apply(themeId: String, fontFamily: String, fontSize: CGFloat) {
        let font = TerminalFont.font(family: fontFamily, size: fontSize)
        if view.font != font { view.font = font }
        if appliedTheme != themeId {
            appliedTheme = themeId
            TerminalTheme.named(themeId).apply(to: view)
            view.needsDisplay = true
        }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) { session.write(data) }

    // A window drag fires a resize per frame, and each one makes a mosh session
    // repaint in full: send only the size the drag settles on.
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0, (newCols, newRows) != lastSent else { return }
        pendingResize?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingResize = nil
            self.lastSent = (newCols, newRows)
            self.session.resize(cols: Int32(newCols), rows: Int32(newRows))
        }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: work)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // Only http(s): the text came from the remote, which must not be able to
        // launch arbitrary URL schemes on this Mac.
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    func bell(source: TerminalView) {
        if UserDefaults.standard.string(forKey: SettingsKey.bellMode) != "silent" { NSSound.beep() }
    }

    /// OSC 52: a remote command puts text on the pasteboard. Off unless enabled
    /// in Settings, capped, and write-only — nothing answers a read request.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.remoteClipboard),
              content.count <= Self.maxRemoteClipboardBytes,
              let text = String(data: content, encoding: .utf8), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Vends one persistent surface per session id.
@MainActor
@Observable
final class MacSurfaceCache {
    @ObservationIgnored private var surfaces: [UUID: MacTerminalSurface] = [:]

    func surface(for session: TerminalSession) -> MacTerminalSurface {
        if let existing = surfaces[session.id] { return existing }
        let surface = MacTerminalSurface(session: session)
        surfaces[session.id] = surface
        return surface
    }

    func drop(_ id: UUID) { surfaces[id] = nil }
}

/// Embeds a session's persistent terminal view and gives it the keyboard.
struct MacTerminalHost: NSViewRepresentable {
    let surface: MacTerminalSurface
    let themeId: String
    let fontFamily: String
    let fontSize: Double

    func makeNSView(context: Context) -> TerminalView {
        surface.apply(themeId: themeId, fontFamily: fontFamily, fontSize: CGFloat(fontSize))
        let view = surface.view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        surface.apply(themeId: themeId, fontFamily: fontFamily, fontSize: CGFloat(fontSize))
    }
}
