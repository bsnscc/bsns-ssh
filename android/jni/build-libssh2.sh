#!/usr/bin/env bash
# Build libssh2 + OpenSSL from source for Android arm64-v8a (covers the
# Apple-Silicon emulator and real arm64 devices). Same pinned, sha256-verified
# sources as the iOS build (app/vendor/build-cssh.sh) — one auditable crypto
# stack across both platforms. Output: android/jni/prebuilt/arm64-v8a/{include,lib}.
set -euo pipefail

OSSL_VER=3.5.9
SSH2_VER=1.11.1
OSSL_SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
SSH2_SHA=d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7
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

# webauthn-sk patch: adds libssh2_userauth_publickey_raw (sign callback returns
# a complete signature blob), the same FIDO2/sk path the iOS build uses. Without
# it the sk userauth packet is framed in a way OpenSSH rejects as "invalid
# format". Shared with the iOS build (app/vendor/build-cssh.sh applies the same).
for fix in CVE-2025-15661 CVE-2026-55199 CVE-2026-55200 sftp-status-followup; do
  patch -p1 -d "libssh2-$SSH2_VER" < "$HERE/../../app/vendor/patches/libssh2-$fix.patch"
done
echo "==> applying webauthn-sk patch"
( cd "libssh2-$SSH2_VER" && patch -p1 < "$HERE/../../app/vendor/patches/libssh2-1.11.0-webauthn-sk.patch" )

export ANDROID_NDK_ROOT="$NDK"
export PATH="$TC/bin:$PATH"
# Preserve the separately built mosh archive and header in this shared prefix.
rm -rf "$OUT/include/openssl"
rm -f "$OUT/lib/libcrypto.a" "$OUT/lib/libssl.a" "$OUT/lib/libssh2.a"
mkdir -p "$OUT"

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
