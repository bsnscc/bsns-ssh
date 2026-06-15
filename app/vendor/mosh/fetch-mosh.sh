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
MOSH_REF=master

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
grep -oE 'src/google/protobuf/[a-z_/]+\.cc' "$WORK/protobuf-$PB_VER/cmake/libprotobuf-lite.cmake" | sort -u | while read -r f; do
  mkdir -p "$HERE/protobuf/$(dirname "${f#src/}")"
  cp "$WORK/protobuf-$PB_VER/$f" "$HERE/protobuf/${f#src/}"
done

echo "==> copying mosh sources (crypto/network/statesync/terminal/util) into mosh-src/"
mkdir -p "$HERE/mosh-src"
for d in crypto network statesync terminal util; do
  cp "$WORK/mosh/src/$d"/*.cc "$WORK/mosh/src/$d"/*.h "$HERE/mosh-src/" 2>/dev/null || true
done
# Drop the OpenSSL OCB variant + frontend-only/terminfo bits; keep internal OCB.
rm -f "$HERE/mosh-src/ocb_openssl.cc"

echo "==> done. Source tree assembled under $HERE"
rm -rf "$WORK"
