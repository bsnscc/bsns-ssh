# Store listing copy — bsns.SSH

Draft copy for the App Store and Google Play, plus a screenshot shot-list. Voice:
plain, technical, privacy-first; no competitor names; no claims we can't back in
the source. Character limits noted per field.

---

## App Store (iOS)

**App name** (≤30): `bsns.SSH`

**Subtitle** (≤30): `Keys you keep. No middleman.`
_(alt: `SSH & mosh, keys in hardware`)_

**Promotional text** (≤170, updatable without review):
> Your SSH keys live in the Secure Enclave or on your YubiKey and never leave.
> No analytics, no phone-home — only your own connections. Open source.

**Keywords** (≤100, comma-separated, no spaces):
`ssh,mosh,terminal,sftp,ssh client,secure enclave,yubikey,key,proxyjump,sysadmin,devops,server,console`

**Description** (≤4000):
> bsns.SSH is a native SSH and mosh client built on one idea: your keys and your
> config are yours — hardware-protected, with no vendor ever in the middle.
>
> KEYS THAT NEVER LEAVE YOUR HARDWARE
> Generate keys directly in the Secure Enclave, or use a YubiKey over NFC or
> USB-C (PIV). The private key is non-extractable and signing sits behind Face ID
> / Touch ID — it never touches the network, and we never see it.
>
> NO TELEMETRY. AT ALL.
> No analytics, no crash reporting, no phone-home. The only network traffic the
> app makes is your own SSH/mosh sessions and the sync storage you choose. The
> app is open source, so you can confirm this yourself — we even document how.
>
> A REAL TERMINAL
> Multi-session tabs, find, scrollback, a hardware-keyboard-friendly layout,
> snippets, and local command history. mosh keeps your session alive across
> network changes and sleep.
>
> BRING YOUR EXISTING SETUP
> Import your ~/.ssh/config, known_hosts, and keys in seconds. Host-key
> verification is trust-on-first-use: an unknown host asks; a changed key is
> refused, not silently accepted.
>
> YOUR CONFIG, YOUR STORAGE
> Optional encrypted sync over iCloud, Drive, Dropbox, or a file you move by
> hand — the provider only ever sees ciphertext. No account of ours, no server
> of ours.
>
> ALSO
> • SFTP file browsing • local port forwarding • single-hop ProxyJump (the
> bastion is key-authenticated and host-key-verified) • current, pinned crypto
> (OpenSSL 3.5 + libssh2 1.11), built reproducibly from source.
>
> bsns.SSH is from the team behind bsns.cc. Source: github.com/bsnscc/bsns-ssh

**What's New** (first release):
> First public release. Native SSH + mosh, hardware-backed keys (Secure Enclave /
> YubiKey), SFTP, port forwarding, ProxyJump, OpenSSH import, and encrypted config
> sync — with no telemetry.

**Support / Marketing URL:** `https://bsns.cc` · **Privacy policy:** `https://tools.bsns.cc/open-source/privacy`
**Privacy nutrition label:** Data Not Collected (no data is collected or linked).

---

## Google Play (Android)

**App title** (≤30): `bsns.SSH`

**Short description** (≤80):
> SSH & mosh client. Keys in hardware (Keystore/YubiKey). No telemetry. Open source.

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
