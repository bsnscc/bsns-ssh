# Verifying "no telemetry, no phone-home"

bsns.SSH claims it makes **no network connection except the ones you ask for** —
your SSH/mosh sessions and the sync folder you choose. This document states that
claim precisely, explains why you don't have to take our word for it, and gives
the exact steps to confirm it yourself.

## The precise claim

> The app opens a network connection **only** to:
> 1. the host (and port) you type into the connect screen — over SSH (TCP) or, for
>    a bastion, the jump host you configured; mosh additionally opens a UDP flow to
>    that same host;
> 2. a ProxyJump bastion you configured, to reach the target through it; and
> 3. the file/sync provider **you** chose for config sync — and only the encrypted
>    bundle, which that provider handles as opaque ciphertext.
>
> It opens **no** connection to any analytics, crash-reporting, attribution, ad,
> or "home" endpoint of ours. There is no account system and no server we operate.

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
   the device/emulator) and watch the flow list. Expectation: SYNs only to your
   SSH host:port (and your sync provider's domain if you enabled sync). No
   connections to any other host.

### iOS (simulator or device)

1. Run **mitmproxy** / **Charles** / **Proxyman** on your Mac and set the
   device/simulator's HTTP proxy to it.
2. Exercise the app — connect to your host, SFTP, enable sync, background/foreground.
3. Watch the flow list. SSH/mosh is raw TCP/UDP (won't show as HTTP), so also run
   **Wireshark** on the interface and filter to the app's traffic. Expectation:
   the only destinations are your SSH host and your chosen sync provider.

> Note: SSH and mosh are not HTTP, so an HTTP proxy alone won't show them — use a
> packet capture (Wireshark/tcpdump) to see *all* destinations, which is the point.

## The pre-publish gate (what the maintainer runs)

Before the "no telemetry" claim ships in store copy, run the capture above against
a release build and confirm the only egress is the SSH host + sync provider. This
is a release checklist item, not a one-time thing — re-run it whenever a
dependency is added (a new SDK is the usual way telemetry sneaks in).

## Keeping it true (regression guard)

The durable protection is **not** a screenshot but:

- the dependency lockfiles (`android/**/gradle.lockfile`, `app/project.yml`
  exact versions) — a new dependency is a visible, reviewed change; and
- this capture procedure, re-run before each release.

A fully automated CI tripwire (run the app under a network monitor, fail on an
unexpected destination) is the ideal next step; it's noted here as a follow-up
rather than claimed as done.
