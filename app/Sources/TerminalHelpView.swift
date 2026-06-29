import SwiftUI

struct TerminalHelpView: View {
    var showsDoneButton = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                HelpRow(
                    icon: "terminal",
                    title: "SSH sessions",
                    text: "A normal SSH connection opens a remote shell. If the connection drops and you reconnect, the app keeps this local tab and scrollback, but the server usually starts a fresh shell.")
                HelpRow(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "mosh sessions",
                    text: "mosh starts through SSH, then uses UDP so it can roam across Wi-Fi, cellular, sleep, and network changes. It needs mosh-server installed on the host and key-based login.")
                HelpRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Auto reconnect",
                    text: "If mosh resumes but the display stops updating, bsns.SSH rebuilds the mosh connection. With a configured tmux session, reconnect returns to that session; without tmux or screen, the server may open a new shell.")
            } header: {
                Text("How Sessions Work")
            }

            Section {
                HelpRow(
                    icon: "square.stack.3d.up",
                    title: "Use mosh with tmux",
                    text: "For long-running work, enable mosh and set a tmux session name on the Connect screen. bsns.SSH runs tmux new-session -A -s <name>, so reconnects and app relaunches attach to the same server-side session.")
                HelpRow(
                    icon: "server.rack",
                    title: "What tmux preserves",
                    text: "tmux keeps your shell, editor, and running commands alive on the server even if the phone sleeps, changes networks, or the app has to reconnect.")
            } header: {
                Text("Recommended Setup")
            }

            Section {
                HelpRow(
                    icon: "scroll",
                    title: "Normal scrollback",
                    text: "In a regular shell, swipe to move through the terminal output saved on this device. With a hardware keyboard, Command-Up/Down or Shift-Page Up/Down scroll locally.")
                HelpRow(
                    icon: "rectangle.on.rectangle",
                    title: "Full-screen apps",
                    text: "tmux, vim, less, and similar apps use the terminal's alternate screen. In that screen, local scrollback is not available; the remote app owns its own history.")
            } header: {
                Text("Scrolling")
            }

            Section {
                HelpRow(
                    icon: "square.stack.3d.up",
                    title: "tmux button",
                    text: "The tmux button does not start tmux. It sends the configured tmux copy-mode sequence to an already-running tmux session so swipes and Page Up/Page Down move through tmux history. The default is C-b [.")
                HelpRow(
                    icon: "rectangle.on.rectangle",
                    title: "screen button",
                    text: "The screen button does the same for GNU screen. The default is C-a [, and you can change it in Settings if your screen prefix is different.")
                HelpRow(
                    icon: "square.stack.3d.up",
                    title: "Active scroll mode",
                    text: "While active, swipes and Page Up/Page Down send remote navigation keys instead of moving local scrollback. Tap done or press Esc to leave. Swiping up in an alternate-screen session can auto-enter the configured tmux path.")
                HelpRow(
                    icon: "keyboard",
                    title: "Hardware keyboard",
                    text: "In tmux or screen scroll mode, Page Up and Page Down move through remote history. Outside that mode, they go to the remote app. Shift-Page Up and Shift-Page Down scroll local output when available.")
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
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
