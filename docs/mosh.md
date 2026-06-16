# mosh integration plan

mosh (mobile shell) is UDP-based, roams across networks, survives sleep, and
gives instant local echo via predictive display. There is no Swift
implementation; the only faithful, interoperable path (so it talks to the
stock `mosh-server` users already have) is to compile mosh's C++ client and
bridge it to our terminal.

## Status

**The entire mosh + protobuf C++ layer compiles for iOS arm64** (54 files: 30
protobuf-lite + 24 mosh) — crypto (OCB/AES via CommonCrypto), the SSP network,
state-sync, the terminal framebuffer model, the generated protobufs, and our own
framebuffer→ANSI `Display`. The C++ port is de-risked end to end; what remains is
the C++ wrapper, SwiftPM packaging, and the Swift session bridge.

**Proven build recipe** (per-file clang, what the `CMosh` SPM target must mirror):
`-std=c++17 -Imosh-src -Imosh-src/src/include -Iprotobuf -DHAVE_PTHREAD=1 -D_DARWIN_C_SOURCE=1`.
- `config-ios.h` (→ `mosh-src/src/include/config.h`) hand-defines the autotools
  HAVE_* macros for iOS + selects `USE_APPLE_COMMON_CRYPTO_AES=1`. Key gotchas: iOS
  has no `<sys/random.h>`/getentropy → use `HAVE_URANDOM` (reads /dev/urandom);
  `_DARWIN_C_SOURCE` is needed for `IP_TOS`/`NI_MAXHOST` in network.cc.
- mosh's terminfo/curses `Display` is replaced by `display-ansi.cc` (full-repaint
  framebuffer→ANSI via `Cell::get_renditions().sgr()` + `print_grapheme`); its
  private `put_row`/`can_use_erase` are left undefined (never odr-used).
- `terminaldisplay.h` is kept (clean header); `terminaldisplay.cc`,
  `terminaldisplayinit.cc`, `pty_compat.*`, `ocb_openssl.cc` are dropped.

Earlier groundwork (still true):
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

1. ✅ Sources compile for iOS (see Status — recipe + config-ios.h + display-ansi.cc).
2. Write the `MoshClient` C++ wrapper around `Transport<UserStream, CompleteTerminal>`
   (non-template, Swift-callable): create(ip,port,key) / tick / recv / pushInput /
   currentFrameANSI (calls our Display::new_frame on `CompleteTerminal::get_fb()`).
3. Assemble the `CMosh` SwiftPM target (all sources + the recipe flags as
   cSettings/cxxSettings + a module map / `-cxx-interoperability-mode`). Confirm it
   LINKS (Display symbols resolved; protobuf-lite arena/etc.).
4. Swift `MoshSession`: SSH bootstrap (`SSHShell.runExec "mosh-server new -s -l ..."`)
   → parse `MOSH CONNECT <port> <key>` → UDP transport → tick loop → ANSI → SwiftTerm;
   input → `pushInput`. Parallel to `TerminalSession`.
5. UI: a "mosh" toggle on the connect form / a session badge.
6. Predictive echo (`terminaloverlay`) as a follow-up.

Only steps 1 (done) and 3 (link) are verifiable off-device; the live session needs
a real `mosh-server` + network, so 4–5 validate on Graham's device.

Testing needs a real server running `mosh-server` and network roaming, so this
lands and is validated on-device, not in the simulator.

## Android port (2026-06-16)

The Android port reuses this exact vendored tree (`app/vendor/mosh/{protobuf,
mosh-src,moshclient.cpp}`) — the C++ shim and sources are platform-independent;
only the toolchain and `config.h` differ:

- **`android/jni/build-mosh.sh`** compiles all 57 TUs with the NDK clang++ into
  `libmosh.a` (arm64-v8a), using **`android/jni/mosh/config.h`** — the Linux/bionic
  analogue of `config-ios.h`. Crypto uses the bundled internal OCB over **OpenSSL's
  AES** (`USE_OPENSSL_AES`, EVP API — fully OpenSSL-3.x compatible), linking the same
  `libcrypto.a` already built for libssh2; no CommonCrypto. Android also enables the
  Linux-only `HAVE_IP_MTU_DISCOVER` / `HAVE_IP_RECVTOS` that iOS omits.
- **`android/transport/src/main/cpp/mosh_bridge.cpp`** is the JNI over `moshclient.h`,
  with a wake-pipe poll loop (`nativeMoshService` polls the mosh fd + a self-pipe so
  staged input interrupts the poll → low latency). `MoshBridge.kt` / `MoshSession.kt`
  are the Kotlin face (owner-thread loop, `TerminalTransport`). `MoshBootstrap.kt`
  parses `MOSH CONNECT`. The connect screen has a "Use mosh (UDP)" toggle.
- **Status:** compiles, links, bootstraps, opens the UDP transport, and renders the
  live remote framebuffer (proving crypto/protobuf/transport/display end-to-end);
  input reaches the native push. Sustained live session is on-device-pending — the
  Docker-Desktop-Mac UDP-publish + emulator double-NAT collapses the return path
  after the handshake. Same on-device-only gate as iOS.
