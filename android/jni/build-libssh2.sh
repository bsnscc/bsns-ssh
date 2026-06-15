#!/usr/bin/env bash
# Build libssh2 + OpenSSL from source for Android arm64-v8a (covers the
# Apple-Silicon emulator and real arm64 devices). Same pinned, sha256-verified
# sources as the iOS build (app/vendor/build-cssh.sh) — one auditable crypto
# stack across both platforms. Output: android/jni/prebuilt/arm64-v8a/{include,lib}.
set -euo pipefail

OSSL_VER=3.5.1
SSH2_VER=1.11.0
OSSL_SHA=529043b15cffa5f36077a4d0af83f3de399807181d607441d734196d889b641f
SSH2_SHA=3736161e41e2693324deb38c26cfdc3efe6209d634ba4258db1cecff6a5ad461
API=26

NDK="${ANDROID_NDK_ROOT:-/opt/homebrew/share/android-commandlinetools/ndk/27.1.12297006}"
TC="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/prebuilt/arm64-v8a"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
verify(){ [ "$(shasum -a256 "$1" | awk '{print $1}')" = "$2" ] || { echo "CHECKSUM MISMATCH: $1" >&2; exit 1; }; }

cd "$W"
echo "==> fetching + verifying sources"
curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-$OSSL_VER/openssl-$OSSL_VER.tar.gz" -o o.tgz; verify o.tgz "$OSSL_SHA"; tar xzf o.tgz
curl -fsSL "https://github.com/libssh2/libssh2/releases/download/libssh2-$SSH2_VER/libssh2-$SSH2_VER.tar.gz" -o s.tgz; verify s.tgz "$SSH2_SHA"; tar xzf s.tgz

export ANDROID_NDK_ROOT="$NDK"
export PATH="$TC/bin:$PATH"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "==> building OpenSSL (android-arm64, API $API)"
( cd "openssl-$OSSL_VER"
  # -fPIC so the static libs can be linked into libsshbridge.so (a shared lib).
  ./Configure android-arm64 -D__ANDROID_API__=$API no-shared no-tests no-apps no-docs no-engine -fPIC --prefix="$OUT" --libdir=lib >cfg.log 2>&1 \
    || { echo "openssl configure failed"; tail -20 cfg.log; exit 1; }
  make -j8 >mk.log 2>&1 || { echo "openssl build failed"; tail -25 mk.log; exit 1; }
  make install_sw >/dev/null 2>&1 )

echo "==> building libssh2 (against that OpenSSL)"
( cd "libssh2-$SSH2_VER"
  export CC="$TC/bin/aarch64-linux-android$API-clang"
  export AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib"
  export CFLAGS="-fPIC"
  export CPPFLAGS="-I$OUT/include"
  export LDFLAGS="-L$OUT/lib"
  ./configure --host=aarch64-linux-android --prefix="$OUT" --with-crypto=openssl \
    --with-libssl-prefix="$OUT" --disable-shared --enable-static \
    --disable-examples-build >cfg.log 2>&1 || { echo "libssh2 configure failed"; tail -30 cfg.log; exit 1; }
  make -j8 >mk.log 2>&1 || { echo "libssh2 build failed"; tail -25 mk.log; exit 1; }
  make install >/dev/null 2>&1 )

echo "==> done: $OUT"
ls -la "$OUT/lib"/*.a
