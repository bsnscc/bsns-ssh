# bsns-ssh — Android

The Android port. Shares the design, the encrypted-bundle sync format, and the
core wire/crypto contracts with the iOS app; see `../docs/android-port.md` for
the architecture and decisions.

## Modules

- **`:core`** — pure Kotlin/JVM, platform-independent: SSH wire codec (done),
  and (incoming) signature framing, known_hosts, and the config-bundle envelope.
  Ported from Swift `BsnsSSHCore` and held byte-identical to it by **shared
  parity test vectors** (`core/src/test/...` mirror the iOS `SSHWireTests`). This
  is the cross-platform contract: signatures and sync bundles must match exactly.

  ```sh
  ./gradlew :core:test
  ```

Planned (need the Android NDK + an emulator/device, not yet set up here):

- **`:transport`** — libssh2 + OpenSSL over the NDK (reusing `../app/vendor/build-cssh.sh`
  with NDK slices), the SSH sign callback bridging over JNI to the platform
  signer. This is the chosen transport (one auditable crypto stack across both
  platforms); the JNI sign-bridge to a StrongBox key is the spike to prove first.
- **`:app`** — Jetpack Compose UI; Keystore/StrongBox + YubiKey (yubikit-android)
  key backends; Storage Access Framework sync.
