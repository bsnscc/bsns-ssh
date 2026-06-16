# Android port — transport & hardware-key design

> **Historical (2026-06):** these decisions are SHIPPED — the Android app is built
> and at feature parity with iOS (libssh2-NDK transport, JNI sign-bridge to a
> Keystore/StrongBox or YubiKey key, mosh, SFTP, ProxyJump, sync). Kept as the
> design record; for current state see `../README.md` and `../android/README.md`.

Status: **decision doc, pre-code.** Decide the transport and hardware-key
direction here before scaffolding, because those two choices shape every layer
above them.

## What carries over

The iOS work already established the seams a second platform reuses:

- **The agent is the heart.** Every connection authenticates through an agent
  that signs without exposing the key. Android keeps this: the agent calls a
  platform signer (Keystore / YubiKey) the same way iOS calls its sign callback.
- **`TerminalTransport` boundary** — one interface over an SSH shell and a mosh
  session. Android reimplements the two transports behind the same shape.
- **The encrypted config bundle** (`PBKDF2-SHA256` 210k + `AES-256-GCM`, envelope
  `bsns-config-aesgcm-v1`) is the sync payload. **Hard requirement: Android must
  produce/consume byte-identical bundles** so a config pushed from iOS pulls on
  Android and vice-versa. This is the most important cross-platform contract.

These are concepts, not code — the Swift core doesn't cross to Kotlin directly
(see "Shared core" below).

## Decision 1 — SSH transport

The linchpin: the library must let us **sign with a non-extractable key** (the
whole product thesis), the way libssh2's sign callback does on iOS.

### Option A — sshj (pure JVM)  ← recommended for v1

[sshj](https://github.com/hierynomus/sshj) authenticates from a `java.security.PrivateKey`,
and **Android Keystore / StrongBox keys present exactly that**: a handle that
signs in hardware and never exposes bytes. This is proven in the wild —
[Android-Password-Store](https://github.com/android-password-store/Android-Password-Store/wiki/Generate-SSH-Key)
generates its SSH key in the Keystore/StrongBox and authenticates over sshj,
including ed25519. So the non-extractable guarantee holds with no NDK.

- **Pros:** fastest path to a working client; idiomatic Kotlin/JVM; ed25519 +
  modern algorithms supported; hardware signing via standard JCA; large user base.
- **Cons:** a *second* SSH implementation to track alongside iOS's libssh2 (two
  audit surfaces). Known gotcha: sshj defaults signature ops to the BouncyCastle
  provider, but Keystore-backed keys must use the `AndroidKeyStore` provider —
  handled by adjusting provider order / not forcing BC (the APS code shows the
  pattern). For a YubiKey we supply a custom signer wrapping the PIV applet.

### Option B — libssh2 over the NDK

Reuse our exact iOS stack: OpenSSL 3.5 + libssh2 1.11.0 (`build-cssh.sh` is
already structured to add NDK slices). The agent sign callback calls back into
Kotlin/JCA over JNI for hardware signing.

- **Pros:** **one** crypto+transport stack across both platforms — audit once,
  identical algorithm policy and sign-callback model; mosh (C++) needs the NDK
  on Android anyway, so the toolchain isn't wasted.
- **Cons:** JNI bridging for the sign callback + I/O is real work; slower to a
  first working client; more build complexity.

### Decision — libssh2 over the NDK (chosen 2026-06-15)

**libssh2-NDK.** Stack uniformity and verifiability outweigh speed-to-v1 for a
product whose whole pitch is doing key management right and *verifiably*:

- **One crypto+transport stack across both platforms.** Same OpenSSL 3.5 +
  libssh2 1.11.0, same explicit algorithm allowlist, same sign-callback model —
  audited once, not twice. sshj would have meant a second implementation
  (BouncyCastle), a second CVE surface, and the algorithm policy kept in parity
  by hand.
- **The NDK isn't an extra cost here** — mosh's C++ requires the NDK toolchain on
  Android regardless, so libssh2 rides along; `build-cssh.sh` is already
  structured to add NDK slices.
- **The sign-callback ports identically.** libssh2 calls our callback, which calls
  the platform signer (Keystore P-256 / YubiKey) over JNI — the exact shape of
  the iOS `AgentSignBridge`, so the "key never touches the transport" guarantee
  is the same code path conceptually on both platforms.

Cost we're accepting: JNI plumbing for the sign callback + non-blocking I/O, and
a slower first working client than sshj would have given. The JNI sign-bridge is
the linchpin — prove it in the spike before anything else.

**Rejected: sshj.** Proven for non-extractable Keystore signing and faster to a
working client, but it's a second SSH stack (two audit surfaces, parity burden)
with a fiddly BouncyCastle-vs-AndroidKeyStore provider conflict — and it doesn't
even save us the NDK, since mosh needs it anyway.

## Decision 2 — Hardware keys

- **Android Keystore / StrongBox** is the Secure Enclave analogue — and on
  StrongBox devices it's a *dedicated secure chip*. Generate EC **P-256** with
  `KeyGenParameterSpec` + `setIsStrongBoxBacked(true)` + `setUserAuthenticationRequired(true)`
  (biometric/credential gate). Non-extractable by construction; signs via JCA.
  As on iOS (Enclave = P-256 only), standardize on P-256 for the hardware path;
  ed25519 Keystore support is newer/less universal — treat as a later add.
- **YubiKey** via [yubikit-android](https://github.com/Yubico/yubikit-android)
  (PIV over USB-C + NFC) — same applet/slot model as the iOS YubiKey backend, so
  good parity.
- **FIDO2 `sk-` keys** are more tractable on Android than iOS, but keep them v2
  for parity and scope.

## Decision 3 — Terminal view

There's no SwiftTerm for Android. **Because we're GPLv3 now**, the battle-tested
GPLv3 terminal widgets are license-compatible — notably Termux's
`terminal-emulator` / `terminal-view`, which many clients reuse. Recommend
starting from that rather than writing a VT parser from scratch; a custom Compose
renderer is a later option if we want tighter control. (This is a concrete upside
of the mosh-driven GPLv3 decision.)

## Decision 4 — Sync

The **Storage Access Framework** is the direct analogue of the iOS Files-provider
approach: `ACTION_OPEN_DOCUMENT_TREE` grants a *persistable* URI permission to a
folder in any provider (Drive, Dropbox, local), so the same "storage you control,
provider sees only ciphertext, no SDK/account" model ports cleanly. The passphrase
goes in the Keystore (this-device-only), mirroring iOS. **Reuse the exact bundle
format** (Decision constraint above) so sync is cross-platform.

## Decision 5 — Shared core

The Swift `BsnsSSHCore` (wire codec, agent protocol, known_hosts, key-backend
shapes, crypto envelope) is small and pure. Two ways to share it:

- **Reimplement in Kotlin** (recommended): it's a few hundred lines of
  deterministic logic; a Kotlin port with a parity test-vector suite (feed both
  platforms the same inputs, assert identical bytes — especially for the SSH
  signature framing and the config envelope) is simpler than the alternative and
  keeps each platform idiomatic.
- **Kotlin Multiplatform** sharing the pure logic: tempting, but the valuable
  parts (Keystore, JCA, transport) are platform-specific anyway, so KMP would
  share the least-risky code while adding build complexity. Not worth it for v1.

The parity test-vectors are the real cross-platform safety net — build them first.

## mosh on Android

mosh stays C++ over the NDK (same vendored 1.4.0 + protobuf-lite). Independent of
the SSH-transport choice; schedule it after the SSH client + terminal work, as on
iOS.

## Recommended stack (v1)

| Layer | Choice |
|-------|--------|
| SSH transport | **libssh2 + OpenSSL 3.5 over the NDK** (`build-cssh.sh` + NDK slices); sign callback → JNI → Keystore/YubiKey |
| Hardware keys | Android Keystore/StrongBox (P-256) + yubikit-android (PIV) |
| Terminal | Termux `terminal-view` (GPLv3-compatible) |
| Sync | Storage Access Framework + Keystore passphrase, shared bundle format |
| Core logic | Kotlin reimplementation + cross-platform parity test-vectors |
| UI | Jetpack Compose |
| mosh | NDK C++ (later) |

## Phased plan

0. **Spike (do first):** libssh2 built for one NDK ABI, authenticating to a real
   server where the sign callback bridges over JNI to a StrongBox-generated P-256
   key — prove non-extractable hardware signing through the JNI bridge end to end
   before building on it (the Android analogue of the iOS libssh2 spike, plus the
   JNI sign-bridge which is the new risk).
1. Kotlin core + parity test-vectors (wire codec, signature framing, config envelope).
2. Agent + libssh2 (JNI) transport authenticating through it.
3. Terminal view on a live session.
4. Keystore/StrongBox key generation + biometric gate.
5. known_hosts (TOFU) + key install.
6. YubiKey (PIV) backend.
7. Sync (SAF) — cross-platform bundle verified against iOS.
8. mosh (NDK).

## Open questions for Graham

1. ~~sshj vs libssh2-NDK~~ — **decided: libssh2-NDK** (stack uniformity +
   verifiability; 2026-06-15).
2. **Minimum Android version / StrongBox** — StrongBox is Pixel 3+/many flagships;
   TEE-backed Keystore covers the rest. Target API level?
3. **UI parity vs. platform-native** — mirror the iOS layout, or lean into
   Material/Compose conventions where they differ?
