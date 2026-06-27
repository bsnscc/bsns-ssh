import SwiftUI

struct TerminalHelpView: View {
    var body: some View {
        List {
            Section {
                HelpRow(
                    icon: "scroll",
                    title: "Normal scrollback",
                    text: "In a regular shell, swipe to move through local terminal scrollback. With a hardware keyboard, Command-Up/Down or Shift-Page Up/Down scroll locally.")
                HelpRow(
                    icon: "rectangle.on.rectangle",
                    title: "Full-screen apps",
                    text: "tmux, vim, less, and similar apps use the terminal's alternate screen. In that screen, local scrollback is not available; the remote app owns history.")
            } header: {
                Text("Scrolling")
            }

            Section {
                HelpRow(
                    icon: "square.stack.3d.up",
                    title: "tmux scroll mode",
                    text: "Use the tmux button in the toolbar or key bar, or press Command-Option-S, to send the configured tmux copy-mode sequence. The default is C-b [.")
                HelpRow(
                    icon: "rectangle.on.rectangle",
                    title: "screen scroll mode",
                    text: "Use the screen button to send the configured GNU screen copy-mode sequence. The default is C-a [, but you can change it in Settings if your screen prefix is different.")
                HelpRow(
                    icon: "square.stack.3d.up",
                    title: "Active scroll mode",
                    text: "While active, panning and Page Up/Page Down send remote navigation keys instead of local scrollback. Tap done or press Esc to leave. Swiping up in an alternate-screen session can auto-enter the configured tmux path.")
                HelpRow(
                    icon: "keyboard",
                    title: "Hardware keyboard",
                    text: "In tmux or screen scroll mode, Page Up and Page Down move a page through remote history. Outside that mode, they go to the remote app. Shift-Page Up and Shift-Page Down scroll local output when available.")
                HelpRow(
                    icon: "hand.tap",
                    title: "Hand icon",
                    text: "The hand icon in the software-keyboard accessory toggles terminal mouse reporting. It is not tmux scrollback.")
            } header: {
                Text("Multiplexer Scroll")
            }

            Section {
                HelpRow(
                    icon: "magnifyingglass",
                    title: "Find",
                    text: "Use the Find button to search local scrollback. It does not search tmux history until tmux has printed that text into the terminal.")
                HelpRow(
                    icon: "photo.on.rectangle.angled",
                    title: "Image paste",
                    text: "Paste or drop an image onto a terminal to upload it over SFTP and insert the remote path at the cursor.")
            } header: {
                Text("Tools")
            }
        }
        .navigationTitle("Terminal Help")
    }
}

private struct HelpRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(Brand.accent)
        }
    }
}
