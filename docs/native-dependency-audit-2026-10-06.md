# Native dependency release audit — 2026-10-06

## Updated inputs

| Component | Previous | Updated source |
| --- | --- | --- |
| OpenSSL | 3.5.1 | 3.5.9 security patch release |
| libssh2 | 1.11.0 | 1.11.1 plus three security backports |

Apple and Android recipes use identical archive checksums and patch ordering.
Archive SHA-256:

- OpenSSL: `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a`
- libssh2: `d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7`

OpenSSL's checksum was checked against the upstream GitHub release asset digest.
The libssh2 checksum pins the archive downloaded from its upstream release.
The existing security-key signature patch applies after the security backports.
Its filename still names the original 1.11.0 base; it also applies to this base.

## Why the release tarball is insufficient

libssh2 1.11.1 includes strict key exchange support for the Terrapin mitigation,
but newer upstream fixes have not been included in a newer published tarball.
The following maintained 1.11.1 backports are checked into `app/vendor/patches`:

| Advisory | Upstream commit | Area |
| --- | --- | --- |
| CVE-2025-15661 | `2dae3024897e1898d389835151f4e9606227721d` | SFTP response parsing |
| CVE-2026-55199 | `17626857d20b3c9a1addfa45979dadcee1cd84a4` | Extension count validation |
| CVE-2026-55200 | `97acf3dfda80c91c3a8c9f2372546301d4a1a7a8` | Transport packet-length bounds |

Backport provenance: Debian maintainer patches, discussed with upstream in
https://github.com/libssh2/libssh2/issues/2125 . Download locations:

- https://salsa.debian.org/debian/libssh2/-/raw/master/debian/patches/CVE-2025-15661.patch
- https://salsa.debian.org/debian/libssh2/-/raw/master/debian/patches/CVE-2026-55199.patch
- https://salsa.debian.org/debian/libssh2/-/raw/master/debian/patches/CVE-2026-55200.patch

The checked-in copies, not those mutable URLs, are the build inputs. Consult the
actual diffs for implementation details; this table is not a complete CVE inventory.

OpenSSL release notes: https://openssl-library.org/news/openssl-3.5-notes/ .
Many fixes concern TLS/CMS/QUIC paths outside normal SSH use. Updating the pinned
library does not imply every listed vulnerability was reachable in this app.

## Validation required for the final artifact

- Apply all patches cleanly to the verified upstream archive.
- Build every Apple architecture and the supported Android ABI.
- Confirm library versions in produced artifacts; rebuild the app against them.
- Exercise SSH authentication, exec, SFTP, and supported security-key signatures.
- Repeat the release archive and physical-device acceptance checks.

Do not treat a previous archive built before this native rebuild as the candidate.

### Backport compatibility and follow-up

The SFTP backport used `LIBSSH2_UNCONST`, which 1.11.1 does not define. Here it
uses `buf.data = data`: the local variable is already `unsigned char *`. This
is the compatibility adjustment discussed with upstream in issue #2125.

The patch set also includes upstream commit
`4ed26f5740bdd409269ed9fb48a28bf8f565b681`, which moves consumption of the SFTP
request ID before parsing a STATUS response. Without that follow-up, the original
security patch interprets the request ID as the status code. The build applies
this follow-up before the existing security-key signature patch.

The earlier pin also cited libssh2 issue #1519. Upstream traced that ECDSA
failure to OpenSSL versions through 3.0.7; newer OpenSSL worked in the report.
Our transport harness tests Ed25519 and ECDSA authentication with this build:
https://github.com/libssh2/libssh2/issues/1519 . Hardware-backed signing still
requires its separate device acceptance test.
