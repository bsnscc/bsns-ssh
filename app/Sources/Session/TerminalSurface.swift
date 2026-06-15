import UIKit
import SwiftTerm

/// The persistent UIKit terminal for one session: the `TerminalView`, its
/// delegate wiring, and a `TerminalHandle`. Kept alive by `TerminalSurfaceCache`
/// for the life of the session so switching tabs preserves each terminal's
/// on-screen buffer and scrollback — the view is re-embedded, not rebuilt.
@MainActor
final class TerminalSurface: NSObject, TerminalViewDelegate {
    let session: TerminalSession
    let view: ZoomableTerminalView
    let handle = TerminalHandle()

    private var appliedThemeId: String?
    var onZoomChange: ((CGFloat) -> Void)?

    init(session: TerminalSession, themeId: String, fontFamily: String, fontSize: CGFloat) {
        self.session = session
        self.view = ZoomableTerminalView(frame: .zero, font: nil)
        super.init()

        view.terminalDelegate = self
        view.onZoomChange = { [weak self] newSize in self?.onZoomChange?(newSize) }
        view.installZoomGestures()
        view.setFont(family: fontFamily, size: fontSize)
        TerminalTheme.named(themeId).apply(to: view)
        appliedThemeId = themeId
        handle.terminal = view
        handle.captureAccessory()

        // The session forwards output from whichever shell is current, so a
        // reconnect swaps the underlying shell without re-wiring here.
        session.onOutput = { [weak self] bytes in
            DispatchQueue.main.async {
                guard let view = self?.view else { return }
                view.feed(byteArray: bytes)
                view.getTerminal().updateFullScreen()
                view.setNeedsDisplay(view.bounds)
            }
        }
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
        if appliedThemeId != themeId {
            appliedThemeId = themeId
            TerminalTheme.named(themeId).apply(to: view)
            view.getTerminal().updateFullScreen()
            view.setNeedsDisplay(view.bounds)
        }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) { session.write(data) }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session.resize(cols: Int32(newCols), rows: Int32(newRows))
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
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
