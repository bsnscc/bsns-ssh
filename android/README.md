# bsns-ssh — Android

The Android port. Shares the design, the encrypted-bundle sync format, and the
core wire/crypto contracts with the iOS app; see `../docs/android-port.md` for
the architecture and decisions.

## Modules

- **`:core`** — pure Kotlin/JVM, platform-independent: SSH wire codec, signature
  framing, known_hosts, the config-bundle envelope (PBKDF2 + AES-256-GCM), and the
  `ssh_config` / `known_hosts` / OpenSSH-key import parsers. Ported from Swift
  `BsnsSSHCore` and held byte-identical to it by **shared parity test vectors** —
  the cross-platform contract: signatures and sync bundles must match exactly.

  ```sh
  ./gradlew :core:test
  ```

- **`:transport`** — libssh2 + OpenSSL built from source over the NDK (via
  `jni/build-libssh2.sh`, same pinned SHAs as iOS) + mosh (`jni/build-mosh.sh`).
  The SSH sign callback bridges over JNI to the platform signer (a non-extractable
  Android Keystore / StrongBox key, or a YubiKey PIV slot) — one auditable crypto
  stack across both platforms; the private key never reaches the transport. Also
  hosts SFTP, local port forwarding, and ProxyJump tunneling.

- **`:app`** — Jetpack Compose UI; Keystore/StrongBox + YubiKey (yubikit-android)
  key backends; Storage Access Framework for import and encrypted auto-sync;
  vendored Termux terminal-emulator/-view for the VT.

Build a release bundle: `./gradlew :app:bundleRelease` (R8-shrunk, signed from
`keystore.properties`). Dependency versions are pinned in per-module
`gradle.lockfile`.
