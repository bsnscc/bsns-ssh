import SwiftUI

struct TerminalHelpView: View {
    var body: some View {
        List {
            Section {
                HelpRow(
                    icon: "scroll",
                    title: "Normal scrollback",
                    text: "In a regular shell, swipe or use scroll keys to move through local terminal scrollback.")
                HelpRow(
                    icon: "rectangle.on.rectangle",
                    title: "Full-screen apps",
                    text: "tmux, vim, less, and similar apps use the terminal's alternate screen. In that screen, local scrollback is not available; the remote app owns history.")
            } header: {
                Text("Scrolling")
            }

            Section {
                HelpRow(
                    icon: "hand.draw",
                    title: "Remote Scroll",
                    text: "The hand/finger or tmux control switches panning from local scrollback to remote navigation keys.")
                HelpRow(
                    icon: "square.stack.3d.up",
                    title: "tmux copy mode",
                    text: "When you start scrolling in tmux, the app enters copy mode automatically. The shortcut bar shows done; tap it or press esc to leave.")
                HelpRow(
                    icon: "keyboard",
                    title: "Hardware keyboard",
                    text: "Page Up and Page Down go to the remote app. Shift-Page Up and Shift-Page Down scroll local output when local scrollback is available.")
            } header: {
                Text("Remote Scroll")
            }

            Section {
                HelpRow(
                    icon: "magnifyingglass",
                    title: "Find",
                    text: "Use Find from the terminal menu to search local scrollback. It does not search tmux history until tmux has printed that text into the terminal.")
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
