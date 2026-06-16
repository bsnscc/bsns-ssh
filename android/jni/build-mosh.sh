#!/usr/bin/env bash
# Build mosh 1.4.0 + protobuf-lite into a static libmosh.a for Android arm64-v8a.
# Reuses the SAME vendored, pinned source tree as iOS (app/vendor/mosh/{protobuf,
# mosh-src,moshclient.cpp}) — only the toolchain (NDK clang++) and config.h
# (android/jni/mosh/config.h: Linux/bionic + OpenSSL AES, vs iOS CommonCrypto)
# differ. Run app/vendor/mosh/fetch-mosh.sh first to populate the source tree.
# OpenSSL must already be built (android/jni/build-libssh2.sh). Output:
# android/jni/prebuilt/arm64-v8a/lib/libmosh.a + include/moshclient.h.
set -euo pipefail

API=26
NDK="${ANDROID_NDK_ROOT:-/opt/homebrew/share/android-commandlinetools/ndk/27.1.12297006}"
TC="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
CXX="$TC/bin/aarch64-linux-android$API-clang++"
AR="$TC/bin/llvm-ar"

HERE="$(cd "$(dirname "$0")" && pwd)"
MOSH="$HERE/../../app/vendor/mosh"          # the shared iOS source tree
OUT="$HERE/prebuilt/arm64-v8a"
OSSL_INC="$OUT/include"                      # OpenSSL headers from build-libssh2.sh
[ -d "$MOSH/mosh-src/src" ] || { echo "missing $MOSH/mosh-src — run app/vendor/mosh/fetch-mosh.sh" >&2; exit 1; }
[ -f "$OSSL_INC/openssl/evp.h" ] || { echo "missing OpenSSL headers — run build-libssh2.sh first" >&2; exit 1; }

OBJ="$(mktemp -d)"; trap 'rm -rf "$OBJ"' EXIT

# config.h (android) MUST shadow mosh-src/src/include/config.h (iOS) — so its dir
# comes first on the include path.
INCS=(
  -I"$HERE/mosh"                             # android config.h
  -I"$MOSH/include"                          # moshclient.h
  -I"$MOSH/mosh-src"                         # full "src/..." includes
  -I"$MOSH/mosh-src/src/include"
  -I"$MOSH/mosh-src/src/crypto"
  -I"$MOSH/mosh-src/src/network"
  -I"$MOSH/mosh-src/src/terminal"
  -I"$MOSH/mosh-src/src/statesync"
  -I"$MOSH/mosh-src/src/util"
  -I"$MOSH/mosh-src/src/protobufs"
  -I"$MOSH/protobuf"
  -I"$OSSL_INC"
)
CXXFLAGS=(-std=c++17 -fPIC -O2 -DHAVE_PTHREAD=1 -DHAVE_CONFIG_H=1 -Wno-deprecated-declarations)

# Source list: the mosh client wrapper + mosh client sources + protobuf-lite.
SOURCES=("$MOSH/moshclient.cpp")
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$MOSH/mosh-src/src" -name '*.cc' | sort)
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$MOSH/protobuf" -name '*.cc' | sort)

echo "==> compiling ${#SOURCES[@]} translation units for arm64-v8a"
i=0
for src in "${SOURCES[@]}"; do
  o="$OBJ/$(printf '%03d' "$i").o"
  "$CXX" "${CXXFLAGS[@]}" "${INCS[@]}" -c "$src" -o "$o" \
    || { echo "FAILED compiling: $src" >&2; exit 1; }
  i=$((i+1))
done

echo "==> archiving libmosh.a ($i objects)"
mkdir -p "$OUT/lib" "$OUT/include"
rm -f "$OUT/lib/libmosh.a"
"$AR" rcs "$OUT/lib/libmosh.a" "$OBJ"/*.o
cp "$MOSH/include/moshclient.h" "$OUT/include/moshclient.h"

echo "==> done: $OUT/lib/libmosh.a"
ls -la "$OUT/lib/libmosh.a"
