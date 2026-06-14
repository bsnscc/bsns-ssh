import SwiftUI
import SwiftTerm

struct TerminalScreen: View {
    var body: some View {
        TerminalContainer()
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Wraps SwiftTerm's UIKit `TerminalView` for SwiftUI. For now it runs a local
/// echo demo — proving the emulator renders and input/output is wired — before
/// the SSH session feeds it real bytes.
struct TerminalContainer: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.feed(text: "bsns-ssh terminal — local demo.\r\nKeystrokes echo back; SSH wiring comes next.\r\n\r\n$ ")
        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Local echo until a real SSH channel is attached.
            source.feed(byteArray: data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
