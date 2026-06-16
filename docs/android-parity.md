# Android ↔ iOS parity

Audit of the iOS feature set and the plan to replicate it on Android, so we
build toward parity in a few deliberate passes rather than many piecemeal builds.

Status key: ✅ done · 🟡 partial · ❌ missing · ⏭ deferred (post-parity)

## Foundations (not user-visible)

| Capability | iOS | Android |
|---|---|---|
| SSH transport (libssh2 + agent sign) | ✅ `SSHShell` | ✅ NDK `sshbridge` + `SshSession` |
| Non-extractable hardware key | ✅ Secure Enclave | ✅ Keystore (TEE/StrongBox) |
| Interactive PTY | ✅ | ✅ |
| SSH wire codec / agent protocol / key formats | ✅ core | ✅ `:core` (30 tests) — wired (FileKey via `KeyManager`, `SshKeyFormat` fingerprints) |
| known_hosts (TOFU) logic | ✅ | ✅ wired (`KnownHostsStore` + `:core` fingerprints) |
| Config envelope (PBKDF2+AES-GCM) | ✅ | ✅ `:core` (iOS-bundle verified) — wired in `BackupScreen` |
| mosh transport | ✅ | ❌ (NDK C++, later) |

The Android `:core` (agent, FileKey ed25519/ecdsa, KnownHosts, config envelope —
ported + cross-verified) is now wired into the app across passes P3–P6 below.

## Feature parity

| Feature | iOS | Android | Plan |
|---|---|---|---|
| **Real VT terminal** (cursor/colors/vim/htop) | ✅ SwiftTerm | ✅ Termux terminal-view, SSH-backed | **P1 DONE** |
| Special-keys bar (esc/ctrl/tab/arrows) | ✅ | ✅ KeyBar over the keyboard | **DONE** |
| Copy / paste / select | ✅ | ✅ (terminal-view textselection) | DONE |
| Saved hosts | ✅ | ✅ `HostStore` + connect-screen Saved section | **DONE** |
| TOFU host-key verify prompt | ✅ | ✅ verify + dialog + mismatch refuse | **DONE** |
| Multiple sessions + tabs | ✅ | ✅ tab strip + per-session terminal cache | **DONE** |
| Reconnect-on-drop | ✅ | ❌ | P2 |
| Key management (list/generate/delete) | ✅ `KeysView` | ✅ `KeysScreen` (hardware + software, fingerprints, copy/delete) | **P3 DONE** |
| Software keys (ed25519/ecdsa) | ✅ | ✅ `KeyManager` + `FileKey`, encrypted at rest, e2e auth-verified | **DONE** |
| Install key on host (ssh-copy-id) | ✅ | 🟡 password path in connect | P3 |
| Known-hosts manager UI | ✅ | ✅ `KnownHostsScreen` (list trusted + forget) | **DONE** |
| Per-connection key picker | ✅ | ✅ `KeyPicker` on connect screen | **DONE** |
| SFTP file browser | ✅ | ✅ `SftpScreen` + `SftpClient` + JNI SFTP subsystem | **P4 DONE** (list/nav/download/upload/mkdir/delete) |
| Settings (theme/font/cursor/bell/keepawake) | ✅ | ✅ `SettingsScreen` (font/scrollback/cursor-blink/keep-awake/key-bar) | **P5 DONE** (theme/bell deferred) |
| App lock (biometric/passcode) | ✅ | ✅ `LockScreen` + BiometricPrompt, re-lock on background | **DONE** |
| Encrypted config export/import + review | ✅ | ✅ `BackupScreen` + `ConfigBundle` + `:core` `ConfigEnvelope` | **P6 DONE** |
| Cross-device sync (Files/SAF) | ✅ | ✅ SAF export/import (Android↔Android verified) | **DONE** |
| Port forwarding (-L) | ✅ | ✅ `ForwardSession` + JNI direct-tcpip + `PortForwardsScreen` | **DONE** (verified end-to-end) |
| Find-in-scrollback | ✅ | ✅ `TerminalSearch` + search bar in `TerminalPane` | **DONE** (scan buffer, scroll-to-match, ↑/↓, counter) |
| mosh | ✅ | 🟡 built + transport-proven, live session on-device-pending | NDK `libmosh.a` + JNI + `MoshSession` + connect toggle |
| YubiKey (NFC/USB PIV) | ✅ | ❌ | ⏭ (on-device) |
| Secure Enclave ↔ StrongBox + biometric gate | ✅ | 🟡 Keystore non-biometric | P3/P5 (add user-auth requirement) |

## Build passes

- **P1 — Terminal (keystone).** Vendor Termux `terminal-emulator` + `terminal-view`
  (GPLv3, compatible), fork `TerminalSession` to be SSH-backed (feed `SshSession`
  output → `emulator.append`, view input → `SshSession.write`), embed via Compose
  `AndroidView`, add a key bar. Fixes the "can't see + type" problem and unlocks
  everything else.
- **P2 — Connect & sessions.** Wire `HostStore` into the connect screen; TOFU
  prompt backed by `:core` KnownHosts; multiple sessions + a tab strip; reconnect.
- **P3 — Keys. DONE.** `KeysScreen` lists the hardware Keystore key + generated
  software keys (`FileKey` ed25519/ECDSA-P256, AES-GCM-wrapped at rest by a
  Keystore key), with fingerprints, copy-public-key, and delete. `KnownHostsScreen`
  lists trusted TOFU host keys with a forget action. `KeyPicker` on the connect
  screen selects which key authenticates. Verified end-to-end: a generated
  software ed25519 key authenticated to OpenSSH and opened an interactive shell
  (`FileKeySigner` returns the signature body; libssh2 frames it from the blob).
- **P4 — SFTP. DONE.** The JNI bridge gained the libssh2 SFTP subsystem
  (`nativeSftpOpen/List/Read/Write/Mkdir/Remove/Close`) over its own
  authenticated connection (shared `connect_and_auth` helper, host-key verified).
  `SftpClient` serialises all ops onto one thread; `SftpScreen` is the browser
  (folder nav, download/upload via the Storage Access Framework, mkdir, delete),
  reached from a "Files" button on the connect screen. Verified end-to-end against
  OpenSSH: list, navigate in/up, mkdir, delete, and a byte-exact download.
  Note: the first SFTP open after a listing can transiently return EAGAIN even on
  a blocking session — `sftp_open_retry` handles it.
- **P5 — Settings + app lock. DONE.** `SettingsScreen` (a "⚙" on the connect
  header) over a `SettingsStore` (SharedPreferences): font size, scrollback,
  cursor blink, keep-screen-awake, show-key-bar — read by `TerminalHolder` at
  session creation (key bar live). App lock via `androidx.biometric`
  BiometricPrompt (`BIOMETRIC_WEAK | DEVICE_CREDENTIAL`): `LockScreen` gates the
  app at launch and re-locks on every `ON_STOP` (background); `MainActivity` is a
  `FragmentActivity` for the prompt. Verified: bigger font + hidden key bar take
  effect on a new session, and a backgrounded app re-locks and unlocks via PIN.
  Theme/bell and the user-auth-required Keystore key are deferred (terminal-view
  colour plumbing / per-key biometric gate).
- **P6 — Config sync. DONE.** `BackupScreen` (reached from Settings → Backup)
  builds a `ConfigBundle` (hosts, trusted host keys, settings, and — opt-in —
  software private keys), seals it with the shared `:core` `ConfigEnvelope`
  (PBKDF2-SHA256 210k + AES-256-GCM) under a passphrase, and writes it via the
  Storage Access Framework. Import reads + decrypts, shows a review dialog
  (counts), then merges additively. Verified end-to-end Android↔Android: a sealed
  bundle round-trips (1 host / 1 host key / 1 software key / settings), and a wrong
  passphrase is rejected. The envelope format is byte-compatible with iOS (the
  `:core` crypto is cross-verified against an iOS vector); full iOS↔Android bundle
  parity is by-design but not yet exercised against a live iOS device.
- **mosh — built + transport-proven (live session on-device-pending).** `libmosh.a`
  (mosh 1.4.0 + protobuf-lite, the same vendored `app/vendor/mosh` tree as iOS) is
  built for arm64-v8a by `android/jni/build-mosh.sh` with `android/jni/mosh/config.h`
  (Linux/bionic + OpenSSL AES — vs iOS CommonCrypto) and links into `libsshbridge.so`.
  `mosh_bridge.cpp` (JNI, wake-pipe poll loop) drives the plain-C `moshclient` API;
  `MoshSession` (owner-thread loop, implements the shared `TerminalTransport`) and
  `MoshBootstrap` (parse `MOSH CONNECT`) complete it; a "Use mosh (UDP)" toggle on
  the connect screen runs SSH bootstrap (`mosh-server new`) → UDP transport.
  **Verified end-to-end against a real `mosh-server` 1.4.0:** SSH bootstrap →
  `MOSH CONNECT` parse → UDP transport open → framebuffer sync → ANSI render of the
  live remote prompt; keystrokes reach `nativeMoshPush`. The sustained input
  round-trip couldn't be confirmed in this env — Docker-Desktop-for-Mac's UDP
  publish + the emulator's SLIRP double-NAT drops the mosh return path after the
  handshake burst (both directions die, not just upstream → a NAT collapse, not a
  send bug). Live verification needs a real network / on-device, exactly as the iOS
  mosh plan documented. Follow-up: pin the host key on the bootstrap exec
  (`nativeAuthAndExec`) like `nativeOpenShell` does; predictive local echo (v2).
- **Find-in-scrollback — DONE.** `TerminalSearch` scans the Termux buffer
  (history + screen) line by line (`getSelectedText` per row) for a case-insensitive
  substring; a search bar in `TerminalPane` (⌕ toggle) shows the query field
  (auto-focused, terminal View focus cleared so the IME types into it), a match
  counter, and ↑/↓ navigation. Scrolling to a match sets `mTopRow` + `invalidate()`
  — NOT `onScreenUpdated()`, which auto-scrolls back to the bottom. Verified on
  the emulator: `seq 1 90` → find "42" scrolls the scrollback to that line.
- **Port forwarding (-L) — DONE.** One dedicated `ForwardSession` (its own SSH
  connection, isolated from the PTY path) hosts several local forwards. The JNI
  (`nativeForwardOpen/Add/Remove/Service/Close`, owner-thread poll + accept +
  non-blocking pump with half-close) binds a loopback listener per forward and
  opens a `direct-tcpip` channel per inbound connection. `PortForwardsScreen`
  (a "Tunnels" button on the connect screen; the session is hoisted to `App()`
  so tunnels survive navigation) adds/removes forwards and shows status.
  Verified end-to-end: `localhost:7777 → 127.0.0.1:9000` tunnelled a real
  response through the server (the server must allow `AllowTcpForwarding`).
- **Deferred:** YubiKey (needs a physical key + yubikit-android).

> Lifecycle: `MainActivity` declares `configChanges` (orientation/screenSize/
> etc.) so resizing the window, rotating, or entering multi-window does NOT
> recreate the Activity and drop live sessions — Compose just re-lays-out.

> Build note: `BiometricPrompt` needs a `FragmentActivity`, but `biometric:1.1.0`
> pulls an old `fragment` whose `startActivityForResult` clashes with the Compose
> `ActivityResultRegistry` ("Can only use lower 16 bits for requestCode" — breaks
> every SAF launcher). Pin `androidx.fragment:fragment:1.8.5` to resolve it.
