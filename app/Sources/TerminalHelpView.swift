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
                    title: "Scrollback on this device",
                    text: "The app saves output as it scrolls off the top of the screen. Swipe to move through it; the view stays where you put it while new output keeps arriving, and the arrow button (or typing) returns to the latest line. With a hardware keyboard, Command-Up/Down or Shift-Page Up/Down scroll it.")
                HelpRow(
                    icon: "hand.draw",
                    title: "One finger, two fingers",
                    text: "When the remote program has asked for the mouse — tmux with mouse on, most full-screen programs — a one-finger swipe scrolls that program through its own history, like a scroll wheel. A flick keeps going and slows down on its own; touch the screen to stop it. Two fingers always scroll the scrollback saved on this device. Settings can make one finger prefer the device's scrollback instead.")
                HelpRow(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Scrollback over mosh",
                    text: "mosh sends the screen as it changes, not everything that was printed. Output that goes by faster than the screen updates never reaches this device, so its scrollback has gaps after a long burst. The remote's history is the complete one: run tmux and scroll it with one finger (mouse on) or the tmux button, or read it as plain text in the tmux History panel.")
                HelpRow(
                    icon: "rectangle.on.rectangle",
                    title: "Full-screen programs",
                    text: "Editors, pagers, and other full-screen programs draw on the terminal's alternate screen and keep their own history; neither this device nor tmux has scrollback for them (tmux copy mode shows only a few lines). If the program supports the mouse, a one-finger swipe scrolls it.")
            } header: {
                Text("Scrolling")
            }

            Section {
                HelpRow(
                    icon: "square.stack.3d.up",
                    title: "tmux button",
                    text: "The tmux button does not start tmux. It sends the configured tmux copy-mode sequence to an already-running tmux session so swipes and Page Up/Page Down move through tmux history. The default is C-b [. With tmux's mouse mode on you don't need it: a one-finger swipe does the same.")
                HelpRow(
                    icon: "rectangle.on.rectangle",
                    title: "screen button",
                    text: "The screen button does the same for GNU screen. The default is C-a [, and you can change it in Settings if your screen prefix is different.")
                HelpRow(
                    icon: "square.stack.3d.up",
                    title: "Active scroll mode",
                    text: "While active, swipes and Page Up/Page Down send remote navigation keys instead of moving local scrollback. Tap done or press Esc to leave. Over plain SSH, swiping in a full-screen session that hasn't asked for the mouse can auto-enter the configured tmux path.")
                HelpRow(
                    icon: "keyboard",
                    title: "Hardware keyboard",
                    text: "In tmux or screen scroll mode, Page Up and Page Down move through remote history. Outside that mode, they go to the remote app. Shift-Page Up and Shift-Page Down scroll local output when available.")
                HelpRow(
                    icon: "hand.tap",
                    title: "Taps and swipes to the remote",
                    text: "\"Send taps and swipes to the remote\" in the ⋯ menu controls terminal mouse reporting. With it off, taps and swipes stay on this device even when the remote program has asked for the mouse.")
            } header: {
                Text("Multiplexer Scroll")
            }

            Section {
                HelpRow(
                    icon: "rectangle.stack",
                    title: "Windows",
                    text: "⋯ → tmux → Windows lists the session's windows; tap one to switch to it, or + for a new one. It talks to tmux directly, so it works whatever your prefix key is.")
                HelpRow(
                    icon: "text.justify.left",
                    title: "History",
                    text: "⋯ → tmux → History shows the current pane's whole history as ordinary text: scroll it, search it, select and copy from it. The arrows jump between shell prompts, and Copy Last Output takes everything the last command printed. This is tmux's own record, so it is complete even over mosh.")
                HelpRow(
                    icon: "lock.shield",
                    title: "How it connects",
                    text: "The panel opens a second SSH connection to the same host with the same key (one more signature, so one more Face ID prompt for a hardware-backed key) and closes it when you leave. It isn't available through a jump host.")
            } header: {
                Text("tmux Panel")
            }

            Section {
                HelpRow(
                    icon: "text.cursor",
                    title: "Select and copy",
                    text: "Press and hold to select a word, drag to extend, then tap Copy. The selection stays put while output keeps arriving; tap anywhere to dismiss it. With a trackpad or mouse, click and drag.")
                HelpRow(
                    icon: "doc.on.clipboard",
                    title: "Copy from the remote",
                    text: "With \"Let the remote copy to this clipboard\" on in Settings, a program on the server can put text on this device's clipboard (OSC 52). tmux does this whenever you copy in copy mode.")
                HelpRow(
                    icon: "wrench.adjustable",
                    title: "tmux copy over mosh",
                    text: "mosh only passes a clipboard write that names the clipboard, and tmux leaves the name empty. If the app starts tmux for you (mosh with a tmux session name), turn on \"Set tmux up for it over mosh\" in Settings and it is handled. Otherwise add this line to ~/.tmux.conf on the server, then detach and re-attach:\n\nset -as terminal-overrides ',xterm*:Ms=\\E]52;c%p1%.0s;%p2%s\\007'")
            } header: {
                Text("Copying")
            }

            Section {
                HelpRow(
                    icon: "magnifyingglass",
                    title: "Find",
                    text: "Use the Find button to search the scrollback saved on this device; the arrows jump between matches. It does not search tmux history until tmux has printed that text into the terminal.")
                HelpRow(
                    icon: "photo.on.rectangle.angled",
                    title: "Image paste",
                    text: "Paste or drop an image onto a terminal to upload it over SFTP and insert the remote path at the cursor.")
                HelpRow(
                    icon: "keyboard.badge.ellipsis",
                    title: "Shortcut bar",
                    text: "The row of keys under the terminal is yours to arrange in Settings → Customize Shortcut Bar: reorder, remove, add symbols, function keys, tmux commands, or a key that sends any sequence. Ctrl and Alt are sticky — tap one, then the next key is sent with it held. Hold an arrow to repeat it.")
                HelpRow(
                    icon: "doc.on.clipboard.fill",
                    title: "Pasting several lines",
                    text: "When the program on the other end would run each pasted line as it arrives, the app shows the paste and asks first. Programs that take a paste as one block (most shells at their prompt, editors) are not interrupted. Inside tmux or screen the app can't tell the two apart; set Confirm multi-line paste to Always in Settings to be asked there.")
                HelpRow(
                    icon: "network",
                    title: "localhost links",
                    text: "A link to localhost printed by the server points at the server, not this device. Tap it and the app offers to forward that port and open the page in a browser sheet. The forward stays up (see Port Forwarding in the ⋯ menu) until you remove it or close the session. Over mosh the forward rides a second SSH connection.")
            } header: {
                Text("Tools")
            }

            Section {
                HelpRow(
                    icon: "chevron.up.chevron.down",
                    title: "Prompt marks",
                    text: "A shell can mark where each prompt and each command's output begins. When it does, the ⋯ menu gains Previous Prompt, Next Prompt and Copy Last Output. For zsh, add to ~/.zshrc:\n\nprecmd() { print -n '\\e]133;D\\a\\e]133;A\\a' }\npreexec() { print -n '\\e]133;C\\a' }")
                HelpRow(
                    icon: "exclamationmark.bubble",
                    title: "Where marks work",
                    text: "tmux and mosh keep these marks to themselves, so they reach the app only on a plain SSH session outside tmux. Inside tmux, use the History panel: its prompt arrows and Copy Last Output find prompts by pattern (Settings → Prompts) and need no shell setup.")
            } header: {
                Text("Prompts")
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
