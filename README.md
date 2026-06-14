# bsns-ssh

A native iOS SSH client built around one idea: **your keys and config are
yours, hardware-protected, with no vendor ever in the middle.**

- **Hardware-backed, non-extractable keys** — generated in and never leaving the
  Secure Enclave, or held on a hardware security key.
- **Your phone as a hardware security key** for your other machines (roadmap).
- **Encrypted config sync over storage you control** — iCloud, Drive, a git
  repo, a file you move by hand. The provider only ever sees ciphertext. No
  account, no server.
- **No telemetry, no analytics, no phone-home.** The only network traffic is
  your own SSH connections and your own chosen sync storage — verifiable by
  pointing a proxy at it.

## Status

Early development — **pre-v1, not yet usable.** Building in the open.

## Building

The device-independent core (key handling, SSH agent, wire codec, crypto
envelope) builds and tests on macOS with no device:

```sh
swift build
swift test
```

The iOS app target (Secure Enclave, biometrics, hardware tokens, terminal UI)
is added as the build progresses.

## License

[MIT](LICENSE).
