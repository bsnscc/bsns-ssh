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
| SSH wire codec / agent protocol / key formats | ✅ core | ✅ `:core` (30 tests) — **not yet wired into the app** |
| known_hosts (TOFU) logic | ✅ | ✅ `:core` — not wired |
| Config envelope (PBKDF2+AES-GCM) | ✅ | ✅ `:core` (iOS-bundle verified) — not wired |
| mosh transport | ✅ | ❌ (NDK C++, later) |

The Android `:core` already has the agent, FileKey (ed25519/ecdsa), KnownHosts,
and the config envelope ported + cross-verified. The app just doesn't use them
yet — wiring them in is most of the "feature" work below.

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
| Key management (list/generate/delete) | ✅ `KeysView` | ❌ (one fixed Keystore key) | **P3** (use `:core` Agent + FileKey + Keystore) |
| Software keys (ed25519/ecdsa) | ✅ | ❌ (`:core` ready) | P3 |
| Install key on host (ssh-copy-id) | ✅ | 🟡 password path in connect | P3 |
| Known-hosts manager UI | ✅ | ❌ | P3 |
| SFTP file browser | ✅ | ❌ | **P4** (add SFTP to JNI bridge + client + UI) |
| Settings (theme/font/cursor/bell/keepawake) | ✅ | ❌ | **P5** |
| App lock (biometric/passcode) | ✅ | ❌ | P5 (BiometricPrompt) |
| Encrypted config export/import + review | ✅ | ❌ (`:core` ready) | **P6** |
| Cross-device sync (Files/SAF) | ✅ | ❌ | P6 (Storage Access Framework) |
| Port forwarding (-L) | ✅ | ❌ | ⏭ |
| Find-in-scrollback | ✅ | ❌ | ⏭ (terminal-view has search) |
| mosh | ✅ | ❌ | ⏭ (NDK C++) |
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
- **P3 — Keys.** A key-management screen on `:core` Agent + FileKey (software keys)
  and Keystore (hardware); known-hosts manager; per-key install.
- **P4 — SFTP.** Extend the JNI bridge with the libssh2 SFTP subsystem + a Kotlin
  client + a browser screen (mirror iOS `SFTPBrowserView`).
- **P5 — Settings + app lock.** Theme/font/cursor/bell/keep-awake; BiometricPrompt
  gate; make the Keystore key user-auth-required.
- **P6 — Config sync.** Export/import the `:core` encrypted bundle + a review
  screen; SAF-based cross-device sync (the iOS Files-provider analogue).
- **Deferred:** port forwarding, find, mosh (NDK), YubiKey.
