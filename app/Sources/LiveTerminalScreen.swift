import SwiftUI
import UIKit
import SwiftTerm

private let minFontSize: CGFloat = 8
private let maxFontSize: CGFloat = 30
private let defaultFontSize: CGFloat = 15

/// A terminal bound to a live `SSHShell`: zoom (pinch, ⌘+/⌘-/⌘0, buttons),
/// theme + font selection, and copy/paste.
struct LiveTerminalScreen: View {
    let shell: SSHShell
    let title: String

    @AppStorage("terminal.fontSize") private var fontSize: Double = Double(defaultFontSize)
    @AppStorage("terminal.themeId") private var themeId: String = TerminalTheme.bsnsDark.id
    @AppStorage("terminal.fontFamily") private var fontFamily: String = TerminalFont.families[0]

    @State private var handle = TerminalHandle()
    @State private var keyboardUp = false
    @State private var hwKeyboard = HardwareKeyboardMonitor()

    private var theme: TerminalTheme { TerminalTheme.named(themeId) }

    var body: some View {
        VStack(spacing: 0) {
            LiveTerminalContainer(shell: shell,
                                  fontSize: Binding(get: { CGFloat(fontSize) }, set: { fontSize = Double($0) }),
                                  themeId: themeId,
                                  fontFamily: fontFamily,
                                  hardwareKeyboard: hwKeyboard.isConnected,
                                  handle: handle)
            // Our key row is redundant with SwiftTerm's soft-keyboard accessory,
            // so only show it when the soft keyboard is down. With a physical
            // keyboard it collapses to just Esc (see TerminalKeyBar.minimal).
            if !keyboardUp {
                Divider().overlay(Color(theme.ansi[8].uiColor).opacity(0.5))
                TerminalKeyBar(shell: shell, handle: handle, theme: theme, minimal: hwKeyboard.isConnected)
            }
        }
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { hwKeyboard.start() }
            .onDisappear { hwKeyboard.stop(); shell.disconnect() }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { setZoom(CGFloat(fontSize) - 1) } label: { Image(systemName: "textformat.size.smaller") }
                    Button { setZoom(CGFloat(fontSize) + 1) } label: { Image(systemName: "textformat.size.larger") }
                    settingsMenu
                }
            }
    }

    private var settingsMenu: some View {
        Menu {
            Button { handle.paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            Button { handle.selectAll() } label: { Label("Select All", systemImage: "selection.pin.in.out") }

            Picker("Theme", selection: $themeId) {
                ForEach(TerminalTheme.all) { Text($0.id).tag($0.id) }
            }
            Picker("Font", selection: $fontFamily) {
                ForEach(TerminalFont.families, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            Image(systemName: "textformat")
        }
    }

    private func setZoom(_ size: CGFloat) {
        fontSize = Double(min(maxFontSize, max(minFontSize, size)))
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
}

/// SwiftTerm's `TerminalView` with font-size zoom via pinch and ⌘ keys.
///
/// We use the default CoreGraphics renderer (its native caret sits in the right
/// cell — the Metal renderer's own cursor was permanently offset). CoreGraphics
/// relies on dirty-region tracking and otherwise leaves stale glyphs when the
/// screen clears; the Coordinator calls `updateFullScreen()` after each feed to
/// force a full repaint, which fixes the "new text on old text" garbling.
final class ZoomableTerminalView: TerminalView {
    var onZoomChange: ((CGFloat) -> Void)?
    private var currentSize: CGFloat = defaultFontSize
    private var pinchStart: CGFloat = defaultFontSize
    private var fontFamily: String = TerminalFont.families[0]

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
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
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

    @objc private func zoomIn() { onZoomChange?(min(maxFontSize, currentSize + 1)) }
    @objc private func zoomOut() { onZoomChange?(max(minFontSize, currentSize - 1)) }
    @objc private func zoomReset() { onZoomChange?(defaultFontSize) }
}

struct LiveTerminalContainer: UIViewRepresentable {
    let shell: SSHShell
    @Binding var fontSize: CGFloat
    let themeId: String
    let fontFamily: String
    let hardwareKeyboard: Bool
    let handle: TerminalHandle

    func makeCoordinator() -> Coordinator { Coordinator(shell: shell, fontSize: $fontSize) }

    func makeUIView(context: Context) -> ZoomableTerminalView {
        let terminal = ZoomableTerminalView(frame: .zero, font: nil)
        terminal.terminalDelegate = context.coordinator
        terminal.onZoomChange = { newSize in context.coordinator.fontSize.wrappedValue = newSize }
        terminal.installZoomGestures()
        terminal.setFont(family: fontFamily, size: fontSize)
        TerminalTheme.named(themeId).apply(to: terminal)
        handle.terminal = terminal
        handle.captureAccessory()
        handle.setAccessorySuppressed(hardwareKeyboard)
        context.coordinator.attach(terminal)
        return terminal
    }

    func updateUIView(_ terminal: ZoomableTerminalView, context: Context) {
        terminal.setFont(family: fontFamily, size: fontSize)
        handle.setAccessorySuppressed(hardwareKeyboard)
        if context.coordinator.appliedThemeId != themeId {
            context.coordinator.appliedThemeId = themeId
            TerminalTheme.named(themeId).apply(to: terminal)
            terminal.getTerminal().updateFullScreen()
            terminal.setNeedsDisplay(terminal.bounds)
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let shell: SSHShell
        let fontSize: Binding<CGFloat>
        var appliedThemeId: String?

        init(shell: SSHShell, fontSize: Binding<CGFloat>) {
            self.shell = shell
            self.fontSize = fontSize
            super.init()
        }

        func attach(_ terminal: ZoomableTerminalView) {
            shell.onOutput = { [weak terminal] bytes in
                DispatchQueue.main.async {
                    guard let terminal else { return }
                    terminal.feed(byteArray: bytes)
                    terminal.getTerminal().updateFullScreen()
                    terminal.setNeedsDisplay(terminal.bounds)
                }
            }
            shell.onClosed = { [weak terminal] in
                DispatchQueue.main.async {
                    guard let terminal else { return }
                    terminal.feed(text: "\r\n[connection closed]\r\n")
                    terminal.getTerminal().updateFullScreen()
                    terminal.setNeedsDisplay(terminal.bounds)
                }
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            shell.write(data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            shell.resize(cols: Int32(newCols), rows: Int32(newRows))
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), UIApplication.shared.canOpenURL(url) else { return }
            UIApplication.shared.open(url)
        }
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
