# Third-party notices

bsns-ssh is licensed under the **GNU General Public License, version 3 or later**
(see `LICENSE`). Copyright © 2026 Graham Saathoff.

The app is a combined work that links the components below. Because one of them
(mosh) is under GPLv3, the combined binary is governed by GPLv3: anyone we
distribute the app to is entitled to the complete corresponding source under the
terms of the GPL.

## Components

| Component | Version | License | Use |
|-----------|---------|---------|-----|
| [mosh](https://mosh.org) | 1.4.0 | **GPL-3.0-or-later** | UDP/roaming terminal transport |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.13.0 | MIT | terminal emulator / view |
| [libssh2](https://libssh2.org) | 1.11.0 | BSD-3-Clause | SSH transport |
| [OpenSSL](https://openssl.org) | 3.5.1 | Apache-2.0 | crypto backend for libssh2 |
| [yubikit-swift](https://github.com/Yubico/yubikit-swift) | 1.3.0 | Apache-2.0 | YubiKey PIV over NFC / USB-C |
| [Protocol Buffers (lite)](https://github.com/protocolbuffers/protobuf) | 3.20.3 | BSD-3-Clause | mosh wire format |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 | transitive (yubikit-swift) |

The MIT, BSD-3-Clause, and Apache-2.0 components are all GPLv3-compatible, so
they combine cleanly into the GPLv3 whole.

## mosh and the App Store

mosh is GPLv3. Apple's App Store terms of service conflict with some GPLv3
rights, but the mosh copyright holders have published an explicit exception
(`COPYING.iOS` in the mosh distribution): they commit not to pursue a license
violation arising **solely** from the GPLv3 ↔ App Store ToS conflict, *provided
we comply with the GPL in every other respect — including providing users with
the source code and the text of the license.*

What this means for distribution:

- We may ship bsns-ssh (with mosh) through the App Store / TestFlight.
- We must offer the complete corresponding source of the app to its users, and
  include the GPLv3 text. Keeping this repository public satisfies that, as long
  as the published source matches what we ship.
- The app cannot be relicensed to permissive/proprietary terms while it links
  mosh. (Removing mosh would lift that constraint.)

## Reproducing the dependency builds

- libssh2 + OpenSSL are built from pinned, sha256-verified source by
  `app/vendor/build-cssh.sh`.
- mosh + protobuf are fetched at pinned commits/releases and sha256-verified by
  `app/vendor/mosh/fetch-mosh.sh`.
- SwiftTerm, yubikit-swift, and swift-argument-parser are pinned to exact
  versions in `app/project.yml`.
