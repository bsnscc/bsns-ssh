# Your first connection

You need a server with SSH enabled, its address and SSH port, and an account on
that server. bsns.SSH is a client; it does not provide a hosted development server.
No bsns.cc registration is needed.

1. Open **Connect**. Enter your server address, username, and SSH port. The normal
   SSH port is 22; use the port your administrator configured, such as 443.
2. For a first test, use password authentication if your server permits it and
   leave **Use mosh** off. Otherwise import a software key or install the public
   half of a supported device/token key in the server's `authorized_keys`.
3. Connect. Verify the host-key fingerprint through a trusted source before
   accepting it. A changed key should be investigated, not accepted blindly.
4. Run `whoami` and `pwd`. The terminal toolbar provides Find and a keyboard
   toggle on iPhone/iPad. The shortcut row supplies keys absent from a phone keyboard.
5. Save the host for future connections. You can open additional sessions without
   closing the first one.

## Working across devices

Use tmux on the execution host to preserve work through a network disconnect.
Attach to that same host and session from another device to access the same
running programs. A different host has different running programs, even when
workspace names match. tmux alone does not preserve processes through a reboot.

Supported Apple builds offer Workspaces for shared host/path/window definitions.
See [host setup](../host/README.md) for the helper and login recovery. A helper
restores shells and directories, not in-flight processes. Install it on each
execution host; nothing runs locally on iPhone or iPad.

For optional configuration sync, choose the same provider folder and passphrase
on each device, push from the configured device, then pull on the others. Keep a
secure copy of the passphrase: we cannot recover it. Hardware private keys cannot
be copied to another device; use a supported token, paired-device signing, or a
separately authorized key there. Software keys can travel in encrypted backups.

## Troubleshooting

- **Timeout:** check the hostname, port, routing, server firewall, and network.
  A server listening for SSH on port 443 still needs a network that permits SSH
  traffic; it is not an HTTPS tunnel.
- **Authentication failed:** check the username, server authentication policy,
  and the selected key. Successful network connection does not prove credentials.
- **Mosh fails but SSH works:** mosh needs a compatible server executable and UDP
  reachability. Use plain SSH if UDP is blocked.
- **Host key changed:** verify with the server administrator before updating trust.
- **Sync unavailable:** confirm the provider is signed in, the folder is accessible,
  and the passphrase matches. Other terminal features do not require sync.
- **Cloud messages unavailable:** confirm both devices are paired, signed into the
  appropriate iCloud account, and configured for the relay. Notification denial
  or service availability can prevent background delivery.

Report ordinary problems at <https://github.com/bsnscc/bsns-ssh/issues>. Include
platform, OS, app build, connection type, and reproducible steps. Redact hostnames,
addresses, transcripts, and logs; never attach private keys or passwords.
Report vulnerabilities privately as described in [SECURITY.md](../SECURITY.md).
