# Shared tmux workspaces

BSNS SSH owns the shared workspace definitions. Its encrypted configuration sync
carries the project, host paths, session name, and saved windows between devices.
Each execution host needs tmux, Python 3, and this helper:

```sh
python3 host/install-workspaces.py
```

Install on each host separately. This installs `~/.local/bin/bsns-workspace`,
a `dev` shortcut, tmux defaults, and a LaunchAgent that restores cached workspaces
at login. It backs up replaced files. It never starts a window's tool automatically.

Opening a workspace with saved windows from an updated app sends a structured
snapshot to the chosen host. The helper saves it under `~/.config/bsns-ssh/workspaces`.
At login, the host restores that last applied snapshot even if the app is closed.
An edit on another device reaches this cache the next time the workspace is opened
on this host. Use the same sync folder and passphrase in the app on every device.
Older app builds do not understand saved windows; update all devices before editing
these definitions from them.

Window IDs track roles across renames. Existing windows and running programs stay
alive. Missing windows open a login shell in their saved directory; temporary
windows remain untouched. Index/name collisions with unmanaged windows fail visibly
rather than replacing them. Session `0` can be retained by entering it explicitly
in the workspace editor. No commands are accepted in the synced window definitions.

```sh
dev up                 # Restore missing windows from all cached workspaces
dev open Development   # Restore and attach/switch to a workspace
dev list Development   # Show its saved window roles
dev doctor Development # Check directories, and that each window's tool is defined and installed
dev resume             # In a window with a tool, run that tool's resume command
dev resume ARGUMENT    # The same, with one argument appended
```

## Tools

A saved window can carry a tool label — a short name such as `editor` or
`review`. The label is all that travels with the workspace; what it runs is
defined on each host, in `~/.config/bsns-ssh/tools.json`:

```json
{
  "editor": { "resume": ["nvim", "-S", "Session.vim"] },
  "logs":   { "resume": ["tail", "-f", "log/development.log"] }
}
```

`dev resume`, run inside a window, starts that window's tool in the window's
directory. A label with no entry on this host is reported, not guessed at, and
a window without a label is a plain shell. Because the commands live on the host
and never in the synced definition, nothing arriving by sync can choose what runs.

Edit shared names and window membership in BSNS SSH, not the host cache. A tool
label selects the manual resume command, not an automatic startup command. Neither
running processes nor work in progress inside them survive a host reboot. Separate hosts
run separate processes; multiple devices connected to one host share its processes.
All saved windows start with one full-screen pane, which works on phones and tablets;
existing splits are preserved. `window-size latest` follows the active client's size.

Login recovery is after user login, not before FileVault unlock. See
`~/Library/Logs/bsns-ssh/workspaces-error.log` for missing directories or conflicts.
Uninstall login recovery with `launchctl bootout gui/$(id -u)/cc.bsns.ssh.workspaces`,
then remove its plist from `~/Library/LaunchAgents`. Existing tmux sessions survive.
