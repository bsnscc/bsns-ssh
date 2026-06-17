# Security policy

bsns.SSH is an SSH/mosh client: it holds keys and opens authenticated sessions to
your servers. We take reports seriously and would rather hear about a problem
early and privately.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting:

> **Security** tab → **Report a vulnerability**
> (<https://github.com/bsnscc/bsns-ssh/security/advisories/new>)

This opens a private advisory visible only to you and the maintainers. Include:

- what you found and where (file/line, screen, or build),
- how to reproduce it (a minimal sequence is ideal),
- the platform and app version (Settings → About, or the build number), and
- the impact you think it has.

What to expect:

- An acknowledgement within **3 business days**.
- A first assessment (severity, whether we can reproduce) within **7 business
  days**.
- We'll keep you updated through the advisory, credit you if you'd like, and
  coordinate a disclosure timeline once a fix is ready.

If you can't use GitHub, you can reach the maintainer through the contact on the
GitHub profile that owns this repository.

## Scope

In scope: the iOS and Android apps and the shared transport/crypto code in this
repository — key handling, host-key verification, the SSH/mosh transports,
ProxyJump, config import/sync, and the agent.

Out of scope: vulnerabilities in your own servers, in third-party SSH servers,
or in the upstream dependencies themselves (report those upstream — though we
do want to know if our *use* of one is unsafe).

## Supported versions

This is pre-1.0 software under active development. Security fixes land on the
latest release; please report against the most recent App Store / Play / source
build. Older builds are not separately patched.

## Security posture (what the app already does)

So you know the baseline a report would be measured against:

- **Keys never leave secure hardware where possible.** Hardware-backed keys use
  the Secure Enclave, the Android Keystore (StrongBox when the device has it,
  otherwise the TEE), or a YubiKey (PIV); in every case the private key is
  non-extractable and signing happens on the secure element, never in app memory.
  Per-signature user verification differs by backend: the **Secure Enclave** key
  requires Face ID / Touch ID on every signature, and a **YubiKey** requires its
  PIN (cached per session) plus a physical touch. **Android Keystore** keys are
  non-extractable but are *not* currently gated on a per-use biometric/credential
  prompt — the optional app lock gates access to the UI, not each individual
  signature (per-use auth is a planned opt-in). Software keys are held in an
  in-process SSH agent and never written to the transport.
- **Hosts are verified (TOFU).** Unknown host keys prompt; a *changed* key is
  refused, not silently accepted. ProxyJump verifies the bastion's own key
  before authenticating to it, and the bastion is key/agent-authenticated only.
- **No telemetry.** The app makes no analytics, crash-reporting, or
  phone-home connections. It talks only to the SSH/mosh hosts (and any ProxyJump
  bastion) you configure. See [`docs/no-telemetry-verification.md`](docs/no-telemetry-verification.md).
- **Current, pinned crypto, built reproducibly.** OpenSSL 3.5 + libssh2 1.11,
  compiled from pinned, sha256-verified source on both platforms; dependencies
  are version-locked.
- **Open source.** The complete source is here (GPL-3.0-or-later), so the above
  is auditable rather than asserted.
