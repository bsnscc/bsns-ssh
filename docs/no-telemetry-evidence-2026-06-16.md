# No-telemetry evidence — 2026-06-16 (dev-machine spot check)

This is a **supporting** spot check, not the canonical gate. The canonical
pre-publish artifact is a packet capture of the **release** build on a **real
device / clean emulator**, per [`no-telemetry-verification.md`](no-telemetry-verification.md).
This check is cheap, reproducible on any dev machine, and catches the obvious
failure: an idle app reaching out to anything at all.

## Claim

When bsns.SSH is open but not connected to a host, it makes **no** network
connections — no analytics, no crash reporting, no phone-home.

## Method

Launch the app in the iOS Simulator, leave it on the Connect screen (do not
connect), then list every TCP/UDP socket the app process owns. `-a` ANDs the
process and network filters so only the app's sockets are shown:

```sh
PID=$(pgrep -f "BsnsSSH.app/BsnsSSH")
lsof -nP -a -p "$PID" -i        # internet sockets owned by the app
```

## Result (2026-06-16T18:14:14Z)

Two simulator instances were running (iPhone + iPad), both idle on Connect:

```
pid 76340 → 0 internet sockets
pid 76757 → 0 internet sockets
```

The idle app holds **zero** TCP/UDP sockets to anywhere. Network activity appears
only after the user taps Connect, and then only to the configured host (and any
ProxyJump bastion). This matches the source: there is no analytics/telemetry SDK
or HTTP client wired into startup.

## Still required before publish (canonical gate)

- Build the **release** configuration on a **physical device** (iOS via
  `rvictl` + `tcpdump`) and a **clean Android emulator** (`tcpdump`/PCAPdroid),
  per `no-telemetry-verification.md`.
- Exercise launch → idle → connect → SFTP → background/foreground.
- Confirm the only destinations are the host(s) you configured and your chosen
  sync storage. Commit the resulting `.pcap` summary alongside this file.
