#!/usr/bin/env bash
# Build the CSSH xcframework (libssh2 + a SUPPORTED OpenSSL) from source for iOS
# device + simulator, replacing the EOL-OpenSSL-1.1.1w prebuilt. Run once, then
# build the app. Output: vendor/CSSH/CSSH.xcframework (gitignored).
#
# Crypto is OpenSSL (not mbedTLS) because libssh2's mbedTLS backend lacks
# ed25519/curve25519 — required to reach modern servers. These are plain C
# libraries, so the same per-slice recipe extends to the Android NDK later (add
# slices to the SLICES list with the NDK toolchain).
set -euo pipefail

OSSL_VER=3.5.1
SSH2_VER=1.11.0
OSSL_SHA=529043b15cffa5f36077a4d0af83f3de399807181d607441d734196d889b641f
SSH2_SHA=3736161e41e2693324deb38c26cfdc3efe6209d634ba4258db1cecff6a5ad461

HERE="$(cd "$(dirname "$0")/CSSH" && pwd)"
PATCHES="$(cd "$(dirname "$0")/patches" && pwd)"
W="$(mktemp -d)"; OUT="$W/out"; mkdir -p "$OUT"
trap 'rm -rf "$W"' EXIT
verify(){ [ "$(shasum -a256 "$1" | awk '{print $1}')" = "$2" ] || { echo "CHECKSUM MISMATCH: $1" >&2; exit 1; }; }

cd "$W"
echo "==> fetching + verifying sources"
curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-$OSSL_VER/openssl-$OSSL_VER.tar.gz" -o o.tgz; verify o.tgz "$OSSL_SHA"; tar xzf o.tgz
curl -fsSL "https://github.com/libssh2/libssh2/releases/download/libssh2-$SSH2_VER/libssh2-$SSH2_VER.tar.gz" -o s.tgz; verify s.tgz "$SSH2_SHA"; tar xzf s.tgz

# Patch libssh2 to support the webauthn-sk-ecdsa signature (FIDO2 via a WebAuthn
# API — Apple AuthenticationServices). Stock libssh2 has no webauthn-sk support;
# this adds libssh2_userauth_publickey_raw(), letting the sign callback supply a
# complete signature blob emitted verbatim. The patch is checked in + documented
# (keeps the build-from-pinned-source story auditable). Applied once here, before
# the per-slice copies below.
echo "==> applying webauthn-sk patch"
patch -p1 -d "libssh2-$SSH2_VER" < "$PATCHES/libssh2-1.11.0-webauthn-sk.patch"

# name | openssl-target | sdk | configure-host | arch | min-version-flag
SLICES=(
  "ios-arm64|ios64-xcrun|iphoneos|arm64-apple-darwin|arm64|-mios-version-min=17.0"
  "iossim-arm64|iossimulator-arm64-xcrun|iphonesimulator|arm64-apple-darwin|arm64|-mios-simulator-version-min=17.0"
  "iossim-x86_64|iossimulator-x86_64-xcrun|iphonesimulator|x86_64-apple-darwin|x86_64|-mios-simulator-version-min=17.0"
)

for slice in "${SLICES[@]}"; do
  IFS='|' read -r NAME OTGT SDK HOST ARCH MINF <<< "$slice"
  echo "==> building $NAME"
  P="$OUT/$NAME"; mkdir -p "$P"
  SDKPATH="$(xcrun -sdk "$SDK" --show-sdk-path)"

  # OpenSSL (fresh tree per slice; Configure mutates in place)
  rm -rf "ossl-$NAME"; cp -R "openssl-$OSSL_VER" "ossl-$NAME"
  ( cd "ossl-$NAME"
    ./Configure "$OTGT" no-shared no-tests no-apps no-docs no-engine "$MINF" --prefix="$P/ossl" >cfg.log 2>&1 \
      || { echo "openssl configure failed"; tail -20 cfg.log; exit 1; }
    make -j8 >mk.log 2>&1 || { echo "openssl build failed"; tail -25 mk.log; exit 1; }
    make install_sw >/dev/null 2>&1 )

  # libssh2 against that OpenSSL
  rm -rf "ssh2-$NAME"; cp -R "libssh2-$SSH2_VER" "ssh2-$NAME"
  ( cd "ssh2-$NAME"
    export CC="$(xcrun -find -sdk "$SDK" clang)"
    export CFLAGS="-arch $ARCH -isysroot $SDKPATH $MINF -fno-common"
    export CPPFLAGS="-I$P/ossl/include $CFLAGS"
    export LDFLAGS="-L$P/ossl/lib"
    ./configure --host="$HOST" --prefix="$P/ssh2" --with-crypto=openssl \
      --with-libssl-prefix="$P/ossl" --disable-shared --enable-static \
      --disable-examples-build >cfg.log 2>&1 || { echo "libssh2 configure failed"; tail -25 cfg.log; exit 1; }
    make -j8 >mk.log 2>&1 || { echo "libssh2 build failed"; tail -25 mk.log; exit 1; }
    make install >/dev/null 2>&1 )

  # Merge libssh2 + OpenSSL into one static lib (matches the prebuilt's layout).
  libtool -static -o "$P/libssh2.a" "$P/ssh2/lib/libssh2.a" "$P/ossl/lib/libssl.a" "$P/ossl/lib/libcrypto.a"
done

echo "==> assembling xcframework"
mkdir -p "$OUT/iossim-fat"
lipo -create "$OUT/iossim-arm64/libssh2.a" "$OUT/iossim-x86_64/libssh2.a" -output "$OUT/iossim-fat/libssh2.a"

HDR="$W/Headers"; mkdir -p "$HDR"
cp "$OUT/ios-arm64/ssh2/include/"libssh2*.h "$HDR/"
cat > "$HDR/module.modulemap" <<'EOF'
module CSSH {
    header "libssh2.h"
    header "libssh2_sftp.h"
    header "libssh2_publickey.h"
    export *
}
EOF

rm -rf "$HERE/CSSH.xcframework"
xcodebuild -create-xcframework \
  -library "$OUT/ios-arm64/libssh2.a" -headers "$HDR" \
  -library "$OUT/iossim-fat/libssh2.a" -headers "$HDR" \
  -output "$HERE/CSSH.xcframework"
echo "==> done: $HERE/CSSH.xcframework (libssh2 $SSH2_VER + OpenSSL $OSSL_VER)"
