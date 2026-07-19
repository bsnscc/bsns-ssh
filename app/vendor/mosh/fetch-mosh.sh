#!/usr/bin/env bash
# Assembles the vendored mosh + protobuf-lite source tree for the iOS build.
# Verified path: protobuf-lite 3.20.3 (the last pre-Abseil release, self-contained
# lite runtime) compiles for iOS arm64; mosh uses Apple CommonCrypto + its bundled
# internal OCB (no OpenSSL), zlib is in the SDK, and ncurses is only for mosh's own
# frontend, which we replace with SwiftTerm. Re-run to regenerate.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
PB_VER=3.20.3
MOSH_REF=mosh-1.4.0
# Pinned artifact digests — every download is verified before use.
PB_CPP_SHA=e51cc8fc496f893e2a48beb417730ab6cbcb251142ad8b2cd1951faa5c76fe3d
PROTOC_SHA=f3ac8c37e87cb345a509eef7ec614092995d9423b8effb42c207c8fbdacb97ee
MOSH_COMMIT=bc73a26316ede2a79259d859f8ee309b32412420

verify() { # <file> <expected-sha256>
  local got; got="$(shasum -a 256 "$1" | awk '{print $1}')"
  [ "$got" = "$2" ] || { echo "CHECKSUM MISMATCH for $1: $got != $2" >&2; exit 1; }
}

echo "==> fetching + verifying protobuf $PB_VER (C++ runtime + matching protoc)"
curl -fsSL "https://github.com/protocolbuffers/protobuf/releases/download/v$PB_VER/protobuf-cpp-$PB_VER.tar.gz" -o "$WORK/pb.tgz"
verify "$WORK/pb.tgz" "$PB_CPP_SHA"
tar xz -C "$WORK" -f "$WORK/pb.tgz"
curl -fsSL "https://github.com/protocolbuffers/protobuf/releases/download/v$PB_VER/protoc-$PB_VER-osx-x86_64.zip" -o "$WORK/protoc.zip"
verify "$WORK/protoc.zip" "$PROTOC_SHA"
unzip -oq "$WORK/protoc.zip" -d "$WORK/protoc"
PROTOC="$WORK/protoc/bin/protoc"

echo "==> fetching mosh ($MOSH_REF, pinned commit $MOSH_COMMIT)"
git clone --depth 1 -b "$MOSH_REF" https://github.com/mobile-shell/mosh.git "$WORK/mosh"
got_commit="$(git -C "$WORK/mosh" rev-parse HEAD)"
[ "$got_commit" = "$MOSH_COMMIT" ] || { echo "mosh commit mismatch: $got_commit != $MOSH_COMMIT" >&2; exit 1; }

echo "==> generating mosh protobuf C++ (must match the $PB_VER runtime)"
"$PROTOC" --proto_path="$WORK/mosh/src/protobufs" --cpp_out="$HERE" "$WORK/mosh/src/protobufs"/*.proto

echo "==> copying protobuf-lite runtime (32 .cc + headers) into protobuf/"
mkdir -p "$HERE/protobuf"
rsync -a --include='*/' --include='*.h' --include='*.inc' --exclude='*' \
  "$WORK/protobuf-$PB_VER/src/google" "$HERE/protobuf/"
grep -oE 'src/google/protobuf/[a-z0-9_/]+\.cc' "$WORK/protobuf-$PB_VER/cmake/libprotobuf-lite.cmake" | sort -u | while read -r f; do
  mkdir -p "$HERE/protobuf/$(dirname "${f#src/}")"
  cp "$WORK/protobuf-$PB_VER/$f" "$HERE/protobuf/${f#src/}"
done

echo "==> copying mosh sources, preserving the src/ tree (includes are \"src/...\")"
rm -rf "$HERE/mosh-src"
for d in crypto network statesync terminal util; do
  mkdir -p "$HERE/mosh-src/src/$d"
  cp "$WORK/mosh/src/$d"/*.cc "$WORK/mosh/src/$d"/*.h "$HERE/mosh-src/src/$d/" 2>/dev/null || true
done
# Generated protobufs live under src/protobufs (mosh includes them that way).
mkdir -p "$HERE/mosh-src/src/protobufs"
cp "$HERE"/*.pb.cc "$HERE"/*.pb.h "$HERE/mosh-src/src/protobufs/" 2>/dev/null || true
# Drop the OpenSSL OCB variant; drop mosh's terminfo/curses Display IMPLEMENTATION
# and server PTY bits. We keep terminaldisplay.h (a clean header) and ship our own
# terminaldisplay.cc (framebuffer→ANSI, no terminfo) from display-ansi.cc.
rm -f "$HERE/mosh-src/src/crypto/ocb_openssl.cc"
rm -f "$HERE/mosh-src/src/terminal/terminaldisplay.cc"
rm -f "$HERE/mosh-src/src/terminal/terminaldisplayinit.cc"
rm -f "$HERE/mosh-src/src/util/pty_compat.cc" "$HERE/mosh-src/src/util/pty_compat.h"
cp "$HERE/display-ansi.cc" "$HERE/mosh-src/src/terminal/terminaldisplay.cc"
# Hand-written iOS config.h (no autotools ./configure) goes at src/include/config.h.
mkdir -p "$HERE/mosh-src/src/include"
cp "$HERE/config-ios.h" "$HERE/mosh-src/src/include/config.h"

# Expose Connection::hop_port() on the Transport so the app can force a fresh
# socket on resume from background (instant mosh roaming vs. the ~10s auto-hop).
echo "==> applying networktransport hop() patch"
patch -p1 -d "$HERE/mosh-src" < "$HERE/patches/networktransport-hop.patch"

# recv() resilience: a suspended-then-invalidated UDP socket (mobile OSes do
# this) fails recvmsg with a non-EAGAIN error while staying poll-readable;
# upstream recv() throws at the first such socket, so the hopped socket's
# datagrams behind it in the deque are never read — the frozen-resume bug.
# Skip and prune dead old sockets instead.
echo "==> applying network recv() dead-socket patch"
patch -p1 -d "$HERE/mosh-src" < "$HERE/patches/network-recv-dead-socket.patch"

echo "==> done. Source tree assembled under $HERE"
rm -rf "$WORK"
