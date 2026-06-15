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
MOSH_REF=mosh-1.4.0   # pinned release tag, not a moving branch

echo "==> fetching protobuf $PB_VER (C++ runtime + matching protoc)"
curl -fsSL "https://github.com/protocolbuffers/protobuf/releases/download/v$PB_VER/protobuf-cpp-$PB_VER.tar.gz" | tar xz -C "$WORK"
curl -fsSL "https://github.com/protocolbuffers/protobuf/releases/download/v$PB_VER/protoc-$PB_VER-osx-x86_64.zip" -o "$WORK/protoc.zip"
unzip -oq "$WORK/protoc.zip" -d "$WORK/protoc"
PROTOC="$WORK/protoc/bin/protoc"

echo "==> fetching mosh ($MOSH_REF)"
git clone --depth 1 -b "$MOSH_REF" https://github.com/mobile-shell/mosh.git "$WORK/mosh"

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

echo "==> done. Source tree assembled under $HERE"
rm -rf "$WORK"
