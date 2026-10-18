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
    @State private var showForwards = false
    @State private var tmuxPanel: TmuxPanelChoice?

    private enum TmuxPanelChoice: Identifiable {
        case windows, history
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            MacTerminalHost(surface: surfaces.surface(for: session),
                            themeId: themeId, fontFamily: fontFamily, fontSize: fontSize)
                // Text shouldn't touch the window's edges or the sidebar.
                .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 6))
                .background(Color(nsColor: TerminalTheme.named(themeId).background.uiColor))
                .overlay(alignment: .top) { notice }
        }
        .navigationTitle(session.title)
        .toolbar {
            // A local shell has no connection for these to ride on.
            if !session.isLocal {
            ToolbarItemGroup {
                // tmux beside the terminal needs a second connection, which a
                // jump host has no tunnel for yet.
                if session.spec.jump == nil {
                    Button { tmuxPanel = .windows } label: { Label("tmux Windows", systemImage: "rectangle.stack") }
                        .help("tmux windows")
                    Button { tmuxPanel = .history } label: { Label("tmux History", systemImage: "text.justify.left") }
                        .help("The current tmux pane's history as text")
                }
                Button { showForwards = true } label: {
                    Label(session.forwards.isEmpty ? "Port Forwarding" : "Port Forwarding (\(session.forwards.count))",
                          systemImage: "arrow.left.arrow.right")
                }
                .help("Port forwarding")
            }
            }
        }
        .sheet(isPresented: $showForwards) { MacForwardsView(session: session) }
        .sheet(item: $tmuxPanel) { choice in MacTmuxPanel(session: session, showHistory: choice == .history) }
    }

    /// Transient notices from the session (a forward opened, a remote clipboard write).
    @ViewBuilder private var notice: some View {
        if let status = session.transferStatus {
            Label(status, systemImage: session.transferSymbol)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.bar, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .padding(.top, 8)
        }
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
        let terminal = MacTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        self.view = terminal
        super.init()
        terminal.onImagePasted = { [weak self] data, ext in self?.pasteImage(data, ext: ext) }
        terminal.onFilesReceived = { [weak self] files in self?.receiveFiles(files) }
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

    private func pasteImage(_ data: Data, ext: String) {
        guard session.status == .connected else {
            session.flash("Reconnect before pasting an image", symbol: "exclamationmark.triangle")
            return
        }
        guard session.isLocal else {
            // SFTP cannot yet use the shell's jump-host tunnel.
            guard session.spec.jump == nil else {
                session.flash("Image paste isn't available through a jump host yet", symbol: "exclamationmark.triangle")
                return
            }
            session.uploadImage(data, ext: ext)
            return
        }
        let directory = UserDefaults.standard.string(forKey: SettingsKey.uploadDir) ?? "~/.bsns-ssh-drops"
        let session = session
        Task {
            do {
                let file = try await Task.detached {
                    try MacClipboardImage(data: data, ext: ext).saveLocally(directory: directory)
                }.value
                guard session.status == .connected, let path = WorkspaceCommand.quoted(file.path) else { return }
                session.write(Array((path + " ").utf8)[...])
                session.flash("Saved → \(file.lastPathComponent)", symbol: "photo.on.rectangle.angled")
            } catch {
                session.flash("Image paste failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
    }

    private func receiveFiles(_ files: [URL]) {
        guard session.status == .connected else {
            session.flash("Reconnect before adding files", symbol: "exclamationmark.triangle")
            return
        }
        guard files.allSatisfy({ (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }) else {
            session.flash("Only regular files can be added", symbol: "exclamationmark.triangle")
            return
        }
        if session.isLocal {
            for file in files {
                session.write(Array((Self.shellQuoted(file.path) + " ").utf8)[...])
            }
            return
        }
        guard session.spec.jump == nil else {
            session.flash("File upload isn't available through a jump host yet", symbol: "exclamationmark.triangle")
            return
        }
        session.uploadFiles(files)
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        guard newCols > 0, newRows > 0 else { return }
        pendingResize?.cancel()
        pendingResize = nil
        // Returning to the last sent size must also cancel an intermediate
        // resize, or tmux ends up drawing for dimensions the view no longer has.
        guard (newCols, newRows) != lastSent else { return }
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
        // "localhost" printed by the server means the server's loopback; this
        // Mac's browser would look here instead. Forward the port, then open that.
        if let loopback = LoopbackURL(url), !session.isLocal {
            let session = session
            Task { @MainActor in
                switch await session.forwardLoopback(loopback) {
                case .success(let local):
                    session.flash("Forwarding port \(loopback.remotePort) → \(local.port.map(String.init) ?? "")",
                                  symbol: "arrow.left.arrow.right")
                    NSWorkspace.shared.open(local)
                case .failure(let failure):
                    session.flash("Couldn't forward port \(loopback.remotePort): \(failure.message)",
                                  symbol: "exclamationmark.triangle")
                }
            }
            return
        }
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
        session.flash("Remote copied \(text.count) character\(text.count == 1 ? "" : "s") to the clipboard",
                      symbol: "doc.on.clipboard")
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
