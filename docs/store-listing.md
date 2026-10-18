# Store listings — 2026-10-18

The copy as published. Use it only for features verified on the platform and
build being submitted, and review privacy answers separately using
`privacy-manifest-audit.md`.

## App Store (iPhone and iPad)

**Name:** bsns.SSH

**Subtitle:** SSH keys that can't leak

**Promotional text:** Your SSH key lives in the Secure Enclave and never leaves it. Mosh, SFTP, and tmux built in. Encrypted sync to storage you own. No account, no tracking, no cost.

**Keywords:** terminal,mosh,sftp,tmux,secure enclave,security key,fido2,piv,shell,server,sysadmin,devops,remote

**Description:**

```text
The SSH client whose keys can't be stolen — because they can't be copied. bsns.SSH generates your key inside the Secure Enclave and asks for Face ID or Touch ID when it signs. Free, open source, and private by design: no account, no ads, no analytics.

KEYS THAT NEVER LEAVE THE HARDWARE
• Secure Enclave keys: created on the chip, unlocked with Face ID or Touch ID, impossible to export.
• FIDO2 security keys over USB-C, NFC, or Lightning, and PIV smart cards — the private key stays on the token.
• Software Ed25519 and ECDSA keys when you want a portable key, protected in encrypted backups.
• Every connection signs through a built-in SSH agent, so the network code never sees a private key.

SEE EVERY MACHINE AT A GLANCE
The Machines view lists every tmux window on every host you use, shows what each one is doing, and flags the ones waiting for you — with a local notification when you're elsewhere. Tap one to jump straight into that window.

PICK UP WHERE YOU LEFT OFF
• Open sessions follow you: start on your iPad, continue on your iPhone in the same tmux session.
• Workspaces save each project's hosts, folders, and windows, and restore them on the host after a reboot.
• Mosh keeps sessions alive through network changes and sleep, and reconnects when you return.
• The tmux panel shows a session's windows and full scrollback as native text you can search and select — even over mosh.

MADE FOR IPAD
A sidebar keeps Connect, your Inbox, Machines, Workspaces, and every live session one tap away, each with its status. Open two sessions side by side, drive everything from a hardware keyboard with a full set of shortcuts, use a trackpad or mouse, and work in Split View and Stage Manager.

EVERYTHING YOU NEED ON THE ROAD
Tabs for multiple sessions, find in output, SFTP file browsing, local port forwarding, jump hosts, snippets, a shortcut key bar, and Shortcuts/Siri actions to open a host or workspace. Import your existing ~/.ssh config, known_hosts, and keys in one step.

YOUR SETUP, ON YOUR STORAGE
Sync hosts, keys, and workspaces across devices through a folder you choose — iCloud Drive or any Files provider. Everything is encrypted on the device first; your storage only ever sees ciphertext. There is no bsns server and no account.

PRIVATE BY CONSTRUCTION
The app talks only to your servers and the storage you pick — plus, if you pair your devices, encrypted messages in your private iCloud database and Apple push notifications. No analytics, no tracking SDKs, no crash reports sent anywhere. It's open source, so you can verify that yourself.

OPEN SOURCE, GPLv3
Read the code, report issues, or build it yourself: https://github.com/bsnscc/bsns-ssh

Made by bsns.cc. We build software for running a small business, and we use this client every day to run our own servers. It's free, with nothing to sign up for — if it earns your trust, the rest of our work is at bsns.cc.
```

**Support URL:** https://github.com/bsnscc/bsns-ssh/issues

**Marketing URL:** https://github.com/bsnscc/bsns-ssh

Use the repository until a dedicated SSH product page is published. The root of
`tools.bsns.cc` currently opens the domain-checking tool.

**Privacy URL:** https://tools.bsns.cc/open-source/privacy

**Privacy label:** Reconcile the final data inventory and CloudKit metadata with
Apple's questionnaire before submission. Do not copy an earlier answer blindly.

## App Review notes

Replace all placeholders in App Store Connect, not in this public repository.
Credentials belong in the private review fields. Use a dedicated test account.

```text
bsns.SSH is a general-purpose SSH, mosh, and SFTP client. It does not require a bsns.cc account, purchase, subscription, or external security token.

The previous review could not reach our SSH service on port 22. The review server now accepts SSH on TCP port 443. This is SSH on port 443, not an HTTPS website.

REVIEW SERVER
Host: <REVIEW_HOST>
Port: 443
User: <REVIEW_USER>
Password: supplied in the private review credentials field
Expected SSH host-key fingerprint: <SHA256_FINGERPRINT>

FIRST CONNECTION
1. Open Connect and enter the host, port 443, username, and supplied password.
2. Leave Use mosh OFF for this test. No VPN is needed.
3. Tap Connect. Compare the first-connection host-key fingerprint with the value above, then trust this test host.
4. Run whoami, pwd, and ls. The home directory contains sample files for SFTP.
5. Use the keyboard button to hide and restore the phone keyboard. Find searches terminal output.
6. Optional, SFTP: file browsing uses key authentication. In the Key section tap "Generate an Ed25519 key", keep the password entered, tap "Install my key (ssh-copy-id)", then tap "Browse files (SFTP)".

The account will remain available throughout review and any follow-up. It has no production data or administrator privileges.

OPTIONAL FEATURES
Mosh requires mosh-server on the host and UDP access in addition to SSH on port 443. If UDP is blocked, use plain SSH; changing the SSH port does not tunnel mosh over TCP.
Hardware security tokens, paired-device signing, iCloud messages, sync, and workspace recovery are optional. Basic SSH can be reviewed with only the supplied password. Paired-device and cloud features have additional setup described in the attached demonstration video.

The app's associated domain supports Apple's security-key/passkey authentication flow. Optional cloud messaging uses CloudKit and Apple push notifications; encrypted config sync uses the user's selected file provider. There are no advertising or analytics SDKs.

Demonstration video: <VIDEO_URL_MATCHING_SUBMITTED_BUILD>
Contact: <REVIEW_CONTACT>
```

Attach a video of the submitted build on a physical device showing any optional
hardware-dependent feature that cannot be exercised with the demo credentials.
Confirm every claim about the review VM above before pasting the notes.

## Google Play

**Title:** bsns.SSH

**Short description:** SSH & mosh with keys locked in your phone's hardware. No account, no tracking.

Android ships a smaller set than iOS: no Machines view, Workspaces, session
handoff, tmux panel, phone-as-key, notifications, or Shortcuts-style actions.
Don't claim them on Play. Keystore backing varies by device; the app shows it.

**Full description:**

```text
The SSH client whose key can't be copied off your phone. bsns.SSH creates your key inside the Android Keystore — in StrongBox or the secure environment where your phone has one — and shows you exactly how it's protected. Free, open source, and private by design: no account, no ads, no analytics.

KEYS THAT STAY IN HARDWARE
• A device key generated in the Android Keystore that can never be exported.
• An optional second key that needs your fingerprint or face for every signature.
• FIDO2 security keys and PIV smart cards over NFC or USB-C — the private key never leaves the token, and the same token works on Android and iOS.
• Software Ed25519, ECDSA, and RSA keys when you need a portable key.
• Every login signs through a built-in SSH agent, so the network code never sees a private key.
• Log in with a password once, tap "Install my key", and switch to your hardware key for good.

BUILT FOR TABLETS TOO
On tablets, Chromebooks, and foldables, a sidebar keeps every session one tap away with live status, two servers sit side by side, and Ctrl+Shift keyboard shortcuts switch, split, close, and zoom sessions.

STAY CONNECTED
• Mosh keeps sessions alive as you move between Wi-Fi and mobile data.
• Multiple sessions in tabs, each with a live status dot.
• Reconnect in place when a connection drops — your scrollback stays.
• Jump hosts (ProxyJump) with verified host keys at every hop.

A REAL TERMINAL
Full color and mouse support for vim, htop, and tmux; a shortcut bar for Esc, Ctrl, Tab, and arrows; pinch to zoom; one-tap tmux and screen scrollback; find in output; snippets; and local command history that never leaves the device.

FILES AND TUNNELS
Browse, upload, and download files over SFTP, and forward local ports to services on your servers.

BRING YOUR SETUP
Import your ~/.ssh config, known_hosts, and keys. Sync hosts and keys across devices — including your iPhone and iPad — through a folder you choose with Android's file picker: Google Drive, Dropbox, Nextcloud, or a network share. Everything is encrypted on the device first; the storage only ever sees ciphertext. There is no bsns server and no account.

PRIVATE BY CONSTRUCTION
The app talks only to your servers and the storage you pick. No analytics, no tracking SDKs, no crash reports sent anywhere. Optional app lock and screenshot protection. Open source, so you can verify it yourself.

OPEN SOURCE, GPLv3
https://github.com/bsnscc/bsns-ssh

Made by bsns.cc. We build software for running a small business, and we use this client every day to run our own servers. It's free, with nothing to sign up for — if it earns your trust, the rest of our work is at bsns.cc.
```

**Release notes (1.1):**

```text
• Redesigned: bottom tabs, grouped forms, a cleaner terminal header, and a tidier Keys screen
• Tablets, Chromebooks and foldables: sidebar, two sessions side by side, keyboard shortcuts
• Log in with a password (and install your key in one tap)
• Pinch to zoom the terminal
• Updated for Android 16
```

## Screenshots

Captioned frames on the brand near-black with the accent green, one headline
of five words or fewer plus a short benefit line, unique features first. The
two stores share one frame style. Capture with harmless demo hosts
(`web-1.example`, `db-1.example`) and a 9:41 status bar.

- **iPhone:** Machines view, Secure Enclave keys, terminal with the key bar,
  tmux panel, SFTP, encrypted sync.
- **iPad:** sidebar with live sessions, two terminals side by side, keyboard
  shortcuts, two-pane Connect.
- **Android phone:** terminal (tmux + htop), saved hosts in folders, SFTP,
  privacy, settings. Add a Keys frame captured on a physical phone; an emulator
  reports a software key.
- **Android tablet:** two sessions side by side, sidebar, two-pane Connect.

Play caps the aspect ratio at 2:1, so phone frames are 1080×1920 and tablet
frames 2560×1600. App Store frames are 1320×2868 (iPhone) and 2064×2752 (iPad).
