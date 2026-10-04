# Architecture

bsns.SSH is a native iOS **and Android** SSH/mosh client built around one idea:
**your keys and config are yours, hardware-protected, with no vendor in the
middle.** This document is the map for contributors.

The two apps share their design and contracts: a platform-independent core
(`Sources/BsnsSSHCore` in Swift, `android/core` in Kotlin) holds the SSH wire
codec, agent protocol, key formats, known_hosts, the config-bundle crypto
envelope, and the import parsers — held byte-identical across platforms by shared
parity test vectors. Both build the SSH/mosh transport from the same pinned
source (OpenSSL 3.5 + libssh2 1.11 + mosh), with the sign callback bridging to a
non-extractable platform key (Secure Enclave / Android Keystore-StrongBox / YubiKey).

## Hard product rules

These constrain every decision — an implementation that would break one should
stop and surface the conflict rather than quietly compromise.

- **No account. No telemetry. No analytics. No crash reporting that phones home.**
- **No network calls except (a) the user's own SSH connections, (b) the
  user's own chosen sync storage, and (c) a direct link between the user's own
  paired devices on the local network.** This is a *verifiable* property —
  running a proxy must show nothing else leaving the device. (c) is off until
  the user turns it on, never leaves the local network, and never passes
  through a server.
- **Private keys in hardware are non-extractable by construction** — the point,
  not a limitation to work around.
- **The sync storage provider only ever sees ciphertext** — client-side
  encryption before anything touches Drive / iCloud / a file.

## The agent is the heart

Everything is a signing request to one **agent**; the agent does not care where
a key lives. All SSH connections authenticate *through* the agent, so no
connection ever sees a private key. The agent speaks the SSH-agent protocol
in-process, over a local socket to other programs on a computer, and across the
device link below — the same messages each time, so none of them is a separate
subsystem.

### Phone as a key (the device link)

A phone can lend its hardware-backed keys to a computer the user has paired with
it. The private key never leaves the phone: the computer sends a signing request,
the phone asks its owner (the biometric prompt is the approval and names who is
asking), and only the signature travels back.

- **Finding each other:** the phone advertises `_bsns-key._tcp` on the local
  network while the feature is on and the app is open. There is no relay and no
  rendezvous server; off the same network, the key is simply unavailable.
- **Pairing:** the computer commits to its keys before the phone reveals its
  own, then both show a six-digit code derived from the whole exchange. The user
  confirms it on both screens; a device in the middle would have had to guess
  the code in one attempt. Each side stores the other's long-term public key.
- **Sessions:** each request runs in a fresh mutually-authenticated session
  (X25519 ephemeral and static agreements, HKDF-SHA256, ChaCha20-Poly1305 with
  per-direction counters). An unpaired device gets no answer at all.
- **What is lent:** only keys that require their owner's presence for every
  signature. Software keys stay on the phone.

The protocol lives in `Sources/BsnsSSHCore/DeviceLink.swift`; the computer sees
each lent key as an ordinary backend (`RemoteAgentKey`).

## One machine, several addresses

A saved host can list other addresses for the same machine — a LAN name at
home, a tailnet name away. Wherever a socket is opened, the transport dials
them together, a beat apart in order of preference, and keeps the first that
answers (`RouteRace` in `Sources/BsnsSSHCore/HostRoutes.swift`); a route that
hangs doesn't hold the others back. Every reconnect races again, so a session
follows the machine from one network to another.

The host keeps one name. Host-key trust, saved state and session identity all
hang on the primary name, whichever address was dialed — the key check is what
proves it is the same machine. mosh's UDP goes to the address the bootstrap
connection used.

Hosts with more than one address also show whether they are reachable right
now. That check is a bare connection to the SSH port, closed at once; hosts
with a single address are never checked unasked.

## Sessions that move between devices

With config sync set up, each device keeps one small file of its open sessions
(`bsns-ssh-sessions-<device id>.json`) beside the sync bundle, sealed with the
same passphrase — so the storage provider sees ciphertext, as with the bundle.
One file per device means two devices never write the same file, and the
bundle's own format is untouched. The device id is random and local.

Other devices list those sessions under "On Your Other Devices". Opening one
goes through the ordinary connect path (host-key trust and key choice apply as
usual) and attaches the same tmux session, so it is the work that carries over,
not the connection; a session without tmux opens a new shell on the same
server. A hardware key does not travel: the opening device uses the same key if
it holds it, and otherwise its own key for that host. Work already open on this
device is not offered again, and a device that has published nothing for 30
days drops out of the list. The model is in
`Sources/BsnsSSHCore/SessionHandoff.swift`.

Key backends share one interface (`KeyBackend`, `Sources/BsnsSSHCore/KeyBackend.swift`):

- **`SecureEnclaveKey`** — non-extractable, biometric-gated, **ECDSA P-256**
  (the Secure Enclave is P-256 only; Ed25519 is not Enclave-native — the UI
  surfaces this).
- **`FileKey`** — encrypted at rest, exportable, syncable; Ed25519 / ECDSA P-256.
- **`YubiKeyPIVKey`** — hardware token: smartcard ECDSA over NFC and USB-C,
  producing a normal `ecdsa-sha2-nistp256` key.

FIDO2 `sk-` keys (`ecdsa-sk`) are implemented on both platforms, alongside PIV
(both hardware-token paths are kept). The mechanism differs by platform: Android
uses native CTAP2 (a native `sk-ecdsa-...@openssh.com` assertion through
libssh2's `sk` userauth), while iOS uses Apple's WebAuthn security-key API, which
produces the `webauthn-sk-ecdsa-...@openssh.com` signature variant — carried via
a libssh2 patch (`libssh2_userauth_publickey_raw`). A single hardware key works
on both platforms but needs a separate enrollment (key pair) per platform.

## Stack

- **SSH transport: libssh2 on an OpenSSL backend.** Chosen because client
  public-key auth supports a **sign callback** — the library never sees the
  private key (`libssh2_userauth_publickey`; for a Secure Enclave P-256 key the
  callback returns the inner `mpint(r) || mpint(s)` and libssh2 frames the
  rest). Auth runs off the main thread because the biometric prompt blocks the
  callback synchronously.
- **Crypto backend: OpenSSL 3.5.1 + libssh2 1.11.0, built from source.**
  `app/vendor/build-cssh.sh` compiles both from pinned, sha256-verified sources
  into a `CSSH.xcframework` (device + simulator slices), merged into one static
  library. libssh2 is pinned at 1.11.0 to avoid the 1.11.1 ECDSA regression. The
  recipe is structured to extend to the Android NDK later. (libssh2's mbedTLS
  backend lacks ed25519/curve25519, which is why the crypto backend is OpenSSL.)
- **Terminal: SwiftTerm**, wrapped for UIKit. Output via `feed(byteArray:)`,
  input via the `send(source:data:)` delegate, resize via `sizeChanged` →
  SSH `window-change`. `TERM=xterm-256color`.
- **Config import/export crypto: system libraries, no dependency.** PBKDF2-SHA256
  (CommonCrypto, 210k iterations, 16-byte random salt) derives the key;
  AES-256-GCM (CryptoKit) is the AEAD. See `ConfigBundle.swift` / `ConfigCrypto`.
- **Secure Enclave:** CryptoKit `SecureEnclave.P256` + `LAContext` /
  `SecAccessControl`. A 64-byte raw `r||s` signature is reframed to SSH `mpint`
  form (the sign-padding is the footgun — it's covered by tests).
- **mosh:** upstream mosh 1.4.0 vendored as C++ (with protobuf-lite) behind a
  plain-C interface, no OpenSSL (CommonCrypto OCB). `app/vendor/mosh/fetch-mosh.sh`
  assembles the pinned, sha256-verified source tree. A session bootstraps
  `mosh-server` over an SSH connection, then runs over UDP; the background model
  is reconnect-on-resume (mosh state is server-side).

## Repo layout

- `Package.swift`, `Sources/BsnsSSHCore/`, `Tests/BsnsSSHCoreTests/` — the
  device-independent core (key-backend protocol, agent, SSH wire codec,
  signature framing, crypto envelope, known_hosts). Build/test on macOS with
  `swift build` / `swift test`; no device needed.
- `app/` — the iOS app target, generated by **XcodeGen** from `app/project.yml`
  (the `.xcodeproj` is gitignored — regenerate it). Depends on `BsnsSSHCore`
  (local SPM), SwiftTerm + yubikit-swift (pinned SPM), and the locally-vendored
  `CSSH` and `CMosh` packages.
- `app/Sources/Transport/SSHShell.swift` — the libssh2 transport: the agent
  sign-bridge, the interactive PTY shell (non-blocking `poll` loop, write queue,
  resize), and local port forwarding. `TerminalSession` binds a terminal to a
  `TerminalTransport` (SSH shell or mosh session) so reconnects swap the
  transport without the view knowing.
- `app/vendor/` — `build-cssh.sh` (libssh2 + OpenSSL) and `mosh/fetch-mosh.sh`
  build/assemble the native dependencies; their outputs are gitignored and
  regenerable. They're vendored locally because Xcode's binary-package downloader
  can stall fetching release assets.

## Build

```sh
# core, on macOS
swift build && swift test

# iOS app
cd app && xcodegen generate
xcodebuild -project BsnsSSH.xcodeproj -scheme BsnsSSH \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

First, run `app/vendor/build-cssh.sh` and `app/vendor/mosh/fetch-mosh.sh` to
populate the native dependencies. Xcode needs the Metal toolchain once
(`xcodebuild -downloadComponent MetalToolchain`) — SwiftTerm compiles Metal
shaders. The app target is Swift 5 language mode; the core is Swift 6.

## License

GPLv3 (see `LICENSE`). Because the app links mosh (GPL-3.0), the combined work
is GPLv3; `THIRD-PARTY-NOTICES.md` covers the dependency licenses and mosh's
App Store distribution exception.
