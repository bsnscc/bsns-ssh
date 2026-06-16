# Privacy Policy — bsns.cc open-source apps

_Effective 2026-06-16._

This policy covers **bsns.SSH** and the other open-source apps published by
bsns.cc. These apps are deliberately different from the bsns.cc hosted product:
**they collect nothing.** This is the canonical version; it is also published at
<https://tools.bsns.cc/open-source/privacy>. The app's source is public
(GPL-3.0-or-later), so every claim here is auditable — see
[`docs/no-telemetry-verification.md`](docs/no-telemetry-verification.md).

> Note: this policy applies **only** to the open-source apps. The bsns.cc hosted
> suite (accounts, billing, the SaaS apps) is a separate product with its own
> privacy policy at <https://bsns.cc/privacy>. Nothing here applies to it, and
> nothing there applies to these apps.

## The short version

We do not collect, store, transmit, sell, or share any of your data. There is no
account, no analytics, no crash reporting, no advertising, no tracking, and no
server operated by us that the app talks to. We could not hand over your data
because we never receive it.

## Data we collect

**None.** The apps contain no analytics, telemetry, attribution, advertising, or
crash-reporting SDKs. We do not collect personal information, usage data,
identifiers, diagnostics, or location.

Because we collect nothing, there is nothing for us to retain, delete on request,
or disclose to third parties or authorities.

## Network connections the app makes

The app opens a network connection **only** to destinations **you** specify:

1. the SSH/mosh host (and port) you enter — over SSH (TCP), plus a mosh UDP flow
   if you enable mosh;
2. a ProxyJump bastion you configure, to reach that host through it; and
3. the file/sync storage **you** choose for optional config sync (e.g. iCloud
   Drive, Google Drive, Dropbox, or a file you move yourself) — and only the
   encrypted bundle, which that provider handles as opaque ciphertext.

It makes **no** connection to any analytics, crash-reporting, attribution, ad, or
"home" endpoint of ours. We do not operate a server for these apps.

## Where your data lives

Everything stays on your device or in storage you control:

- **Keys.** Hardware-backed keys are generated in and never leave the Secure
  Enclave (iOS) / Android Keystore (StrongBox when available), or a YubiKey
  (PIV). Software keys are held locally. Private keys never touch the network.
- **Config** (saved hosts, known_hosts, snippets, command history). Stored
  locally. Command history never leaves your device.
- **Optional sync.** If you turn it on, your config is encrypted on-device
  (PBKDF2 + AES-256-GCM) before it is written to the storage provider you chose.
  The provider sees only ciphertext; we are not involved.

## Third parties

The apps use no third-party services that receive your data. They link
open-source libraries (listed in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)),
none of which phone home. Any storage provider you pick for sync is governed by
that provider's own privacy policy, and only ever receives encrypted data.

## Children

The apps are developer tools, not directed at children, and collect no data from
anyone.

## Changes

If this policy changes, we will update the effective date above and the published
version. Because the app is open source, the full history of this document is
visible in the project's version control.

## Contact

Questions about privacy: through the contact on the GitHub profile that owns the
[project repository](https://github.com/bsnscc/bsns-ssh), or via bsns.cc.
