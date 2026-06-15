#!/usr/bin/env bash
# Fetch the vendored libssh2 + OpenSSL xcframework (DimaRU/Libssh2Prebuild,
# libssh2 1.11.0 — pinned to sidestep the 1.11.1 ECDSA regression). We
# reference it by local path because xcodebuild's package downloader stalls
# fetching the GitHub release asset in some environments. The xcframework is
# gitignored; run this once after cloning, before building the app.
set -euo pipefail

TAG="1.11.0-OpenSSL-1-1-1w"
URL="https://github.com/DimaRU/Libssh2Prebuild/releases/download/${TAG}/CSSH-${TAG}.xcframework.zip"
SHA256="f2a14236019b617019f522001c89ad5db2125e8f350cbcde5ed6e96f50842157"
DEST="$(cd "$(dirname "$0")/CSSH" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL"
curl -fL --retry 3 "$URL" -o "$TMP/cssh.zip"
got="$(shasum -a 256 "$TMP/cssh.zip" | awk '{print $1}')"
[ "$got" = "$SHA256" ] || { echo "CHECKSUM MISMATCH: $got != $SHA256" >&2; exit 1; }
unzip -q "$TMP/cssh.zip" -d "$TMP"

# RELEASE GATE: this xcframework links OpenSSL 1.1.1w, which is EOL. Before public
# release, rebuild libssh2 on a supported crypto backend — build OpenSSL 3.x +
# libssh2 into our own xcframework, switch libssh2 to mbedTLS, or move the
# transport to swift-nio-ssh. Tracked in docs/release-readiness-review-2026-06-15.md.
XF="$(find "$TMP" -maxdepth 2 -name CSSH.xcframework -type d | head -1)"
[ -n "$XF" ] || { echo "CSSH.xcframework not found in archive" >&2; exit 1; }
rm -rf "$DEST/CSSH.xcframework"
cp -R "$XF" "$DEST/CSSH.xcframework"
echo "Installed $DEST/CSSH.xcframework"
