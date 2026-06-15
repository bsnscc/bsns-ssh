import SwiftUI
import UIKit
import SwiftTerm

private let minFontSize: CGFloat = 8
private let maxFontSize: CGFloat = 30
private let defaultFontSize: CGFloat = 15

/// A terminal bound to a live `SSHShell`, with zoom (pinch, ⌘+/⌘-/⌘0, buttons).
struct LiveTerminalScreen: View {
    let shell: SSHShell
    let title: String
    @State private var fontSize: CGFloat = defaultFontSize

    var body: some View {
        LiveTerminalContainer(shell: shell, fontSize: $fontSize)
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { shell.disconnect() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { setZoom(fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                    Button { setZoom(fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                }
            }
    }

    private func setZoom(_ size: CGFloat) {
        fontSize = min(maxFontSize, max(minFontSize, size))
    }
}

/// SwiftTerm's `TerminalView` with font-size zoom via pinch and ⌘ keys.
final class ZoomableTerminalView: TerminalView {
    var onZoomChange: ((CGFloat) -> Void)?
    private var currentSize: CGFloat = defaultFontSize
    private var pinchStart: CGFloat = defaultFontSize
    private var metalEnabled = false

    // The default CoreGraphics renderer relies on dirty-region tracking and
    // leaves stale glyphs when the screen is cleared ("new text on old"). The
    // Metal renderer redraws the full visible buffer each frame, which fixes
    // it. Must be enabled once the view is in a window.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !metalEnabled else { return }
        metalEnabled = true
        try? setUseMetal(true)
    }

    func setFontSize(_ size: CGFloat) {
        let clamped = min(maxFontSize, max(minFontSize, size))
        currentSize = clamped
        if abs(font.pointSize - clamped) > 0.1 {
            font = UIFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
        }
    }

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
        (super.keyCommands ?? []) + [
            UIKeyCommand(title: "Zoom In", action: #selector(zoomIn), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "Zoom In", action: #selector(zoomIn), input: "+", modifierFlags: .command),
            UIKeyCommand(title: "Zoom Out", action: #selector(zoomOut), input: "-", modifierFlags: .command),
            UIKeyCommand(title: "Actual Size", action: #selector(zoomReset), input: "0", modifierFlags: .command),
        ]
    }

    @objc private func zoomIn() { onZoomChange?(min(maxFontSize, currentSize + 1)) }
    @objc private func zoomOut() { onZoomChange?(max(minFontSize, currentSize - 1)) }
    @objc private func zoomReset() { onZoomChange?(defaultFontSize) }
}

struct LiveTerminalContainer: UIViewRepresentable {
    let shell: SSHShell
    @Binding var fontSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(shell: shell, fontSize: $fontSize) }

    func makeUIView(context: Context) -> ZoomableTerminalView {
        let terminal = ZoomableTerminalView(frame: .zero, font: nil)
        terminal.terminalDelegate = context.coordinator
        terminal.onZoomChange = { newSize in context.coordinator.fontSize.wrappedValue = newSize }
        terminal.installZoomGestures()
        terminal.setFontSize(fontSize)
        context.coordinator.attach(terminal)
        return terminal
    }

    func updateUIView(_ terminal: ZoomableTerminalView, context: Context) {
        terminal.setFontSize(fontSize)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let shell: SSHShell
        let fontSize: Binding<CGFloat>

        init(shell: SSHShell, fontSize: Binding<CGFloat>) {
            self.shell = shell
            self.fontSize = fontSize
            super.init()
        }

        func attach(_ terminal: ZoomableTerminalView) {
            shell.onOutput = { [weak terminal] bytes in
                DispatchQueue.main.async { terminal?.feed(byteArray: bytes) }
            }
            shell.onClosed = { [weak terminal] in
                DispatchQueue.main.async { terminal?.feed(text: "\r\n[connection closed]\r\n") }
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
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
