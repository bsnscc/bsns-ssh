# Store listing copy — bsns.SSH

Draft copy for the App Store and Google Play, plus a screenshot shot-list. Voice:
plain, technical, privacy-first; no competitor names; no claims we can't back in
the source. Character limits noted per field.

---

## App Store (iOS)

**App name** (≤30): `bsns.SSH`

**Subtitle** (≤30): `Keys you keep. No middleman.`
_(alt: `SSH & mosh, keys in hardware`)_

**Promotional text** (≤170, updatable without review — 145 chars):
> A free, open source SSH/Mosh/SFTP client from bsns.cc. No strings attached. No ads, no account needed, no paywalled features, no data collection.

**Keywords** (≤100, comma-separated — 99 chars):
`mosh,terminal,sftp,ssh client,yubikey,secure enclave,proxyjump,sysadmin,devops,server,console,shell`

**Description** (≤4000 — ~2.4k chars). iOS version below; for **Android** swap
"Secure Enclave" → "Android Keystore (StrongBox where available)" and "Face ID or
Touch ID" → "your fingerprint or device unlock". (Don't name Android in the iOS
listing — Apple flags other-platform references.) App Store descriptions are
**plain text**, so use `•` bullets, not Markdown.

```
bsns.SSH is a native, zero-telemetry SSH and Mosh client built for operators who demand total control over their infrastructure and their data. No accounts, no subscriptions, and zero vendor middle-men.

HARDWARE-BACKED SECURITY
Generate non-extractable keys directly within your device's Secure Enclave, or authenticate seamlessly via a YubiKey (PIV over NFC or USB-C). Your private keys never touch the network, and signing operations sit securely behind Face ID or Touch ID.

ZERO TELEMETRY
We collect absolutely nothing. No analytics, no crash tracking, and no proprietary servers. The only network traffic the app ever creates is your own outbound sessions and your chosen sync destination. It's fully open-source and independently verifiable.

BRING YOUR OWN CLOUD SYNC
Keep your devices in sync without giving up your privacy. Because bsns.SSH saves directly to native OS file providers, you can use iCloud Drive, Google Drive, Nextcloud, Proton Drive, or local network shares without granting third-party API tokens to the app. The cloud provider only ever sees your encrypted ciphertext.

A POWERFUL, NATIVE TERMINAL
• True Mosh Support: Keep your terminal session alive across spotty cellular connections, Wi-Fi hops, and device sleep.
• Desktop-Class Workspace: Multi-session tabs, interactive find, deep scrollback buffers, and a highly customizable hardware-keyboard layout.
• Instant Migration: Import your existing ~/.ssh/config, known_hosts, and software keys in seconds with secure trust-on-first-use host verification.

ADVANCED OPERATOR TOOLS
• In-process SSH agent authentication (keys never touch the transport layer).
• Full SFTP file browsing and local port forwarding.
• Single-hop ProxyJump (key-authenticated and host-verified bastions).
• Built on a modern, pinned crypto stack (OpenSSL 3.5 + libssh2 1.11) compiled reproducibly from source.
• Engineered for accessibility with VoiceOver-labeled controls, Dynamic Type, and high-contrast dark themes.

FULLY OPEN SOURCE (GPLv3)
Review the codebase, audit our no-telemetry claims, or build the app yourself at: github.com/bsnscc/bsns-ssh

bsns.SSH is proudly built and maintained by bsns.cc as part of our Tools for Operators campaign. We believe foundational administration and security utilities should be open, private, and free.

bsns.cc is an operations platform for small business with many tools and a shared memory — because your business shouldn't live in your head.
```

**What's New** (first release):
> First public release. Native SSH + mosh, hardware-backed keys (Secure Enclave /
> YubiKey), SFTP, port forwarding, ProxyJump, OpenSSH import, and encrypted config
> sync — with no telemetry.

**Support / Marketing URL:** `https://bsns.cc` · **Privacy policy:** `https://tools.bsns.cc/open-source/privacy`
**Privacy nutrition label:** Data Not Collected (no data is collected or linked).

**App Review notes** (App Store Connect → App Review Information → Notes). Plain
text; paste verbatim, substituting the demo credentials from the **private** store
console / your password manager. ⚠️ NEVER commit the demo host/user/password to
this repo — it is public. Keep a throwaway, rotatable review account live through
the review window (it's the only way a reviewer can exercise a connection); put
its real credentials only in App Store Connect's App Review Information fields.

```
bsns.SSH is an SSH, Mosh, and SFTP client. No account or registration is required, and the app collects no data.

HOW TO TEST (SSH with a password):  [fill in the demo host/user/password here from the private console — do NOT store them in the repo]
1. Open the app — it starts on the "Connect" tab.
2. Enter:
   • Host: <demo host>
   • Port: 22
   • User: <demo user>
   • Password: <demo password>
3. Tap "Connect".
4. On the first connection the app shows a trust-on-first-use host-key prompt — tap "Trust" to proceed.
5. You'll land in a live interactive shell. Run a command (e.g. ls, whoami) to confirm it works.

This demo account is on a publicly reachable server and will stay active through the review period.

OPTIONAL — to also test Mosh:
On the Connect screen tap "Install my key (ssh-copy-id)" (this uses the password above to add the app's key to the host), then turn on the "Use mosh" toggle and tap Connect. (The demo host has mosh-server installed.)

NOTES:
• Hardware-backed keys are optional and not required to verify the app — they need physical hardware: a FIDO2 security key (NFC or USB-C, via Apple's standard WebAuthn / AuthenticationServices), a smart card / PIV token, or an on-device Secure Enclave key.
• The app's Associated Domains entitlement (webcredentials:tools.bsns.cc) exists only so iOS can validate a FIDO2 security-key credential for SSH — the standard WebAuthn mechanism. It carries no personal data, and that domain is never contacted during your SSH/Mosh sessions (signing happens locally between the device and the key).
• Mosh and ProxyJump use an in-app SSH key (agent) rather than a password.
• "Browse files (SFTP)" on the Connect tab opens an SFTP browser to the same host.
• The app makes no network connections other than to the SSH/Mosh host you enter — no analytics or telemetry.

Thank you for reviewing!
```

---

## Google Play (Android)

**App title** (≤30): `bsns.SSH`

**Short description** (≤80):
> SSH & mosh client. Non-extractable keys (Keystore/YubiKey). No telemetry. OSS.

**Full description** (≤4000): _(reuse the App Store description, with these swaps)_
- "Secure Enclave" → "the Android Keystore (StrongBox when available)"
- "Face ID / Touch ID" → "your fingerprint / device unlock"
- iCloud listed among sync providers → "Drive, Dropbox, or a file you move by hand"

**Data safety form:** No data collected, no data shared. (App makes only the
SSH/mosh and user-chosen sync connections.)

---

## Screenshot shot-list

Shoot on real devices, **dark mode**, with a real but non-sensitive demo host
(use a throwaway box; never show a real hostname/IP, key, or token). Order matters
— the first 2–3 carry the listing.

1. **Terminal in action** — a live session (e.g. `htop` or a colorful `ls`),
   tab bar visible. The hero; shows it's a real terminal.
2. **Connect screen** — clean form, mosh toggle, the "0 analytics" feel. (A dark
   iPhone capture already lives at `docs/images/connect-ios.png`.)
3. **Keys** — a key list showing a Secure Enclave / YubiKey-backed key, with the
   "non-extractable / hardware" affordance.
4. **SFTP browser** — file listing, to show it's more than a shell.
5. **Import from OpenSSH** — config/known_hosts/keys import, the "migrate in
   seconds" story.
6. **(optional) Settings/About** — surfacing "no telemetry" + open-source link.

Device sizes to capture: iPhone 6.9" + 6.5"; iPad 13"; Android phone + 7"/10"
tablet. Caption each with one short benefit line, not a feature name.

> Note: text-heavy app icons can get illegible at launcher size — eyeball the
> icon on a real home screen / launcher before finalizing store assets.
