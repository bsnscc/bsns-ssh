# Vendored dependency license texts

bsns.SSH is **GPL-3.0-or-later** (root [`LICENSE`](../LICENSE)). It is a combined
work; [`../THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md) explains how the
pieces fit and why the whole is GPLv3. This directory holds the **exact, verbatim
upstream license texts** for the vendored / built-from-source components, at the
pinned versions we ship, so the obligations are auditable without chasing links.

| Component | Pinned | License | Text |
|-----------|--------|---------|------|
| mosh | 1.4.0 | GPL-3.0-or-later | [`mosh-1.4.0-COPYING.txt`](mosh-1.4.0-COPYING.txt) |
| mosh — App Store exception | 1.4.0 | (GPLv3 grant) | [`mosh-1.4.0-COPYING.iOS.txt`](mosh-1.4.0-COPYING.iOS.txt) |
| Termux terminal-emulator / terminal-view | (forked) | GPL-3.0-only | [`termux-terminal-LICENSE.md`](termux-terminal-LICENSE.md) |
| └ incorporates Android Terminal Emulator | — | Apache-2.0 | [`Apache-2.0.txt`](Apache-2.0.txt) |
| libssh2 | 1.11.0 | BSD-3-Clause | [`libssh2-1.11.0-COPYING.txt`](libssh2-1.11.0-COPYING.txt) |
| OpenSSL | 3.5.1 | Apache-2.0 | [`openssl-3.5.1-LICENSE.txt`](openssl-3.5.1-LICENSE.txt) |
| Protocol Buffers (lite) | 3.20.3 | BSD-3-Clause | [`protobuf-3.20.3-LICENSE.txt`](protobuf-3.20.3-LICENSE.txt) |
| Bouncy Castle (bcprov-jdk18on) | 1.78.1 | MIT-style (BC) | [`bouncycastle-1.78.1-LICENSE.txt`](bouncycastle-1.78.1-LICENSE.txt) |
| SwiftTerm | 1.13.0 | MIT | [`../app/vendor/SwiftTerm/LICENSE`](../app/vendor/SwiftTerm/LICENSE) |

Notes:

- **mosh's `COPYING`** is the standard GPLv3 — byte-identical to the root
  [`LICENSE`](../LICENSE); it is kept here as the verbatim file mosh ships.
- **`COPYING.iOS`** is mosh's explicit, narrow App Store exception (it does not
  relicense mosh — see `THIRD-PARTY-NOTICES.md` § "mosh and the App Store").
- **Termux** releases its repo GPL-3.0-only; its `terminal-view` /
  `terminal-emulator` modules reuse Apache-2.0 "Android Terminal Emulator" code,
  hence both texts apply to that vendored fork.
- **Apache-2.0** (`Apache-2.0.txt`) also covers OpenSSL, AndroidX/Jetpack Compose,
  Kotlin stdlib + kotlinx.serialization, and the YubiKit SDKs (those arrive via
  pinned package managers, version-locked in `app/project.yml` and the per-module
  `android/**/gradle.lockfile`).
- **Bouncy Castle** (Android software-key math) uses the MIT-style BC license;
  the verbatim text for the locked `bcprov-jdk18on 1.78.1` release is committed as
  [`bouncycastle-1.78.1-LICENSE.txt`](bouncycastle-1.78.1-LICENSE.txt).

These texts are fetched verbatim from the upstream tag/release matching each
pinned version. Refresh them whenever a pinned version changes.
