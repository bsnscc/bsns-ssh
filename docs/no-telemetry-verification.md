# Verifying "no telemetry, no phone-home"

bsns.SSH claims it makes **no network connection except the ones you ask for** —
your SSH/mosh sessions, the sync folder you choose, and (if you enable it) the
local-network link between your own paired devices, and the optional private
iCloud relay for questions and notices. This document states that
claim precisely, explains why you don't have to take our word for it, and gives
the exact steps to confirm it yourself.

## The precise claim

> The app opens a network connection **only** to:
> 1. the host (and port) you type into the connect screen — over SSH (TCP) or, for
>    a bastion, the jump host you configured; mosh additionally opens a UDP flow to
>    that same host;
>    If you gave a saved host more than one address, the app also checks which
>    of those addresses answers — a connection to the SSH port, closed at once —
>    while the host list is on screen;
> 2. a ProxyJump bastion you configured, to reach the target through it;
> 3. the file/sync provider **you** chose for config sync — and only the encrypted
>    bundle, which that provider handles as opaque ciphertext; and
> 4. a device **you** paired for "phone as a key" — directly, encrypted end to
>    end, and only while that feature is on: over the local network, a
>    device-to-device wireless link, or an address you gave on a private network
>    of your own. In a capture this appears as mDNS for `_bsns-key._tcp` and a
>    TCP flow between your two devices' addresses (port 47822 when reached by
>    address); signing requests use the direct link.
> 5. Apple CloudKit and push services for the optional paired-device message
>    relay. Expect encrypted message records plus routing metadata as described
>    in [PRIVACY.md](../PRIVACY.md); do not misclassify these as telemetry.
> 6. Websites you explicitly open from terminal links.
>
> It opens **no** connection to any analytics, crash-reporting, attribution, ad,
> or "home" endpoint of ours. There is no app account system or automatic developer-operated collection endpoint.
> A user-entered review/demo SSH host is still an SSH destination.

We deliberately scope the claim to *network connections*, because that's what's
objectively checkable. "We never learn anything about you" is broader than a
capture can prove — so we don't phrase it that way.

## Why not just trust our screenshot?

You shouldn't, and we don't ask you to. A capture log we publish proves nothing —
we could doctor it, or capture a path that happens not to phone home. The real
basis for trust is, in order:

1. **The source is open** (GPLv3). You can read exactly what the app does — and,
   importantly, a capture only shows *out-of-band* connections; it can't see inside
   the SSH stream you opened. Only the source rules out exfiltration over your own
   session. Source is the primary guarantee; the capture is a convenience.
2. **You can reproduce the build** from pinned, source-built dependencies.
3. **You can run the capture yourself** in a few minutes (below). The value of
   this doc is the *recipe*, not our results.

## Verify it yourself

### Android (emulator or device)

1. Build/install the app.
2. Capture all traffic the app's UID emits and watch for anything that isn't your
   SSH host or sync provider:

   ```sh
   # Emulator: route the app through a logging proxy, or capture at the host.
   # Simplest: PCAP from the emulator and inspect destinations.
   adb shell "tcpdump -n -i any -s0 -w /sdcard/bsns.pcap" &   # rooted/emulator
   # …use the app: connect to YOUR host, browse SFTP, sync…
   adb pull /sdcard/bsns.pcap && open bsns.pcap   # Wireshark
   ```

   For a TLS-aware view, point the app at **mitmproxy** (Settings → Wi-Fi proxy on
   the device/emulator) and watch the flow list. Match observed destinations to the enabled feature inventory above; an HTTP
   proxy alone does not observe SSH or mosh.

### iOS (simulator or device)

1. Run **mitmproxy** / **Charles** / **Proxyman** on your Mac and set the
   device/simulator's HTTP proxy to it.
2. Exercise the app — connect to your host, SFTP, enable sync, background/foreground.
3. Watch the flow list. SSH/mosh is raw TCP/UDP (won't show as HTTP), so also run
   **Wireshark** on the interface and filter to the app's traffic. Expectation:
   destinations match the enabled feature inventory above, including Apple
   services when relay is enabled.

> Note: SSH and mosh are not HTTP, so an HTTP proxy alone won't show them — use a
> packet capture (Wireshark/tcpdump) to see *all* destinations, which is the point.

### Quick idle check (first line, any machine)

The cheapest catch — does the app reach out to *anything* while just sitting on
the Connect screen? List the app process's own sockets (the `-a` ANDs the process
and network filters):

```sh
# iOS Simulator (the app runs as a host process):
PID=$(pgrep -f "BsnsSSH.app/BsnsSSH"); lsof -nP -a -p "$PID" -i

# Android: the app's UID, via the network stats / your capture:
adb shell ss -tunp 2>/dev/null | grep "$(adb shell pm list packages -U cc.bsns.ssh)"
```

For a clean configuration with no saved hosts, sync, discovery, or relay enabled,
expect no app-initiated session traffic. Saved-host route probes and enabled
background features can legitimately create idle traffic. Historical evidence is in
[`no-telemetry-evidence-2026-06-16.md`](no-telemetry-evidence-2026-06-16.md).

## The pre-publish gate (what the maintainer runs)

Before the "no telemetry" claim ships in store copy, run the capture above against
a release build and match egress to the enabled feature inventory. This
is a release checklist item, not a one-time thing — re-run it whenever a
dependency is added (a new SDK is the usual way telemetry sneaks in).

**Pass/fail criteria (release build, on device / clean emulator):**

- PASS: each destination is explained by a configured host, provider, paired
  device, Apple relay/push/associated-domain service, or explicit browser action.
- FAIL: unexplained app-initiated egress, especially analytics, advertising, or
  automatic developer-operated collection. Investigate before asserting telemetry
  is absent. OS-mediated services may not appear as sockets owned by the app.

Capture launch → idle → connect → SFTP → background → foreground, then commit a
short summary of observed destinations next to the dated evidence file above.

## Keeping it true (regression guard)

The durable protection is **not** a screenshot but:

- the dependency lockfiles (`android/**/gradle.lockfile`, `app/project.yml`
  exact versions) — a new dependency is a visible, reviewed change; and
- this capture procedure, re-run before each release.

A fully automated CI tripwire (run the app under a network monitor, fail on an
unexpected destination) is the ideal next step; it's noted here as a follow-up
rather than claimed as done.

## Release capture matrix

Capture the exact Release build on a physical device. Record the build number,
source commit, device/OS, enabled features, destinations, and observed behavior.
Exercise separately: fresh launch with optional features off; SSH/SFTP; mosh;
sync push/pull; direct signing; iCloud relay and notification delivery; link opening.
Distinguish OS/provider traffic from app-initiated traffic. A Wi-Fi HTTP proxy
does not capture arbitrary SSH or UDP; use an interface packet capture. Never
commit packet captures containing real credentials, plaintext, or host metadata.
Publish a redacted destination summary and mark untested paths explicitly.
