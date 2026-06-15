import SwiftUI
import SwiftTerm

/// A terminal bound to a live `SSHShell`: SwiftTerm output ← shell, keystrokes →
/// shell, resize → shell.
struct LiveTerminalScreen: View {
    let shell: SSHShell
    let title: String

    var body: some View {
        LiveTerminalContainer(shell: shell)
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { shell.disconnect() }
    }
}

struct LiveTerminalContainer: UIViewRepresentable {
    let shell: SSHShell

    func makeCoordinator() -> Coordinator { Coordinator(shell: shell) }

    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        context.coordinator.attach(terminal)
        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        let shell: SSHShell

        init(shell: SSHShell) {
            self.shell = shell
            super.init()
        }

        func attach(_ terminal: TerminalView) {
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
