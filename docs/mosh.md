# mosh integration plan

mosh (mobile shell) is UDP-based, roams across networks, survives sleep, and
gives instant local echo via predictive display. There is no Swift
implementation; the only faithful, interoperable path (so it talks to the
stock `mosh-server` users already have) is to compile mosh's C++ client and
bridge it to our terminal.

## Status

Foundation **proven** (build path de-risked), integration **not yet built**.

Verified so far:
- **Crypto needs no OpenSSL.** mosh builds with `--with-crypto-library=apple-common-crypto`
  and ships its own AES-OCB (`ocb_internal.cc`). We use Apple CommonCrypto + the
  internal OCB. `ocb_openssl.cc` is dropped.
- **protobuf-lite 3.20.3** (the last pre-Abseil release; self-contained lite
  runtime, 32 .cc files) **compiles for iOS arm64** — verified by compiling
  `message_lite.cc` and the generated `transportinstruction.pb.cc` with the iOS
  SDK clang. Modern protobuf drags in Abseil and is not worth it here.
- **zlib** is in the iOS SDK; **ncurses/terminfo** is only used by mosh's own
  frontend, which we don't ship — SwiftTerm is the display.
- Generated protobuf C++ is vendored at `app/vendor/mosh/*.pb.{cc,h}`. Re-run
  `app/vendor/mosh/fetch-mosh.sh` to regenerate the whole source tree.

## Build approach

A vendored SwiftPM C++ target (`CMosh`), the same way the SSH library is
vendored — SPM cross-compiles the C++ for iOS as part of the app build, so no
manual xcframework. Sources:
- protobuf-lite runtime (32 .cc) + headers, header search path at the protobuf
  `src` root (includes are `<google/protobuf/...>`).
- mosh `crypto` (internal OCB + CommonCrypto), `network` (the SSP transport),
  `statesync` (`completeterminal`, `user`), `terminal` (mosh's framebuffer
  emulator — needed because the protocol syncs terminal *state*), `util`, and
  the generated `*.pb.cc`.
- Define `HAVE_PTHREAD=1`; select the Apple crypto path.

## Integration design

mosh syncs terminal **state** (a Framebuffer), not a byte stream, so the
`Transport` is a C++ template — `Transport<UserStream, CompleteTerminal>` on the
client. We expose it through a non-template C++ wrapper (`MoshClient`) with a
Swift-callable surface:
- `init(ip, port, base64Key)` — open the UDP transport.
- `tick()` / `recv()` — pump outgoing/incoming datagrams.
- `pushInput(bytes)` — set the user-input state.
- `framebufferDiffANSI()` — turn the latest remote Framebuffer into the minimal
  ANSI escape sequence diff (reuse mosh's `Display::new_frame`) and feed it to
  SwiftTerm.

Bootstrap reuses the existing SSH path: run `mosh-server new -s -c 256 -l ...`
over `SSHShell.runExec`, parse the `MOSH CONNECT <port> <key>` line, then open
the UDP transport to `host:port` with that key. A new `MoshSession` (parallel to
`TerminalSession`) drives the tick loop on a queue and forwards to a
`TerminalSurface`.

**Predictive local echo** (mosh's headline feel) lives in mosh's frontend
overlay, tightly coupled to its own terminal. v1 can ship without it (still
gets roaming + resilience over UDP); fold in `terminaloverlay` afterwards.

## Remaining work (sequenced)

1. Assemble `CMosh` SwiftPM target from `fetch-mosh.sh`; get protobuf-lite +
   mosh `crypto`/`network`/`statesync`/`terminal`/`util` to compile for iOS.
2. Write the `MoshClient` C++ wrapper around `Transport<UserStream, CompleteTerminal>`.
3. Swift `MoshSession`: SSH bootstrap → parse `MOSH CONNECT` → UDP transport →
   tick loop → framebuffer-diff ANSI → SwiftTerm; input → `pushInput`.
4. UI: a "mosh" toggle on the connect form / a session badge.
5. Predictive echo (`terminaloverlay`) as a follow-up.

Testing needs a real server running `mosh-server` and network roaming, so this
lands and is validated on-device, not in the simulator.
