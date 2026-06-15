#!/usr/bin/env bash
# Fetch the vendored libssh2 + OpenSSL xcframework (DimaRU/Libssh2Prebuild,
# libssh2 1.11.0 — pinned to sidestep the 1.11.1 ECDSA regression). We
# reference it by local path because xcodebuild's package downloader stalls
# fetching the GitHub release asset in some environments. The xcframework is
# gitignored; run this once after cloning, before building the app.
set -euo pipefail

TAG="1.11.0-OpenSSL-1-1-1w"
URL="https://github.com/DimaRU/Libssh2Prebuild/releases/download/${TAG}/CSSH-${TAG}.xcframework.zip"
DEST="$(cd "$(dirname "$0")/CSSH" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL"
curl -fL --retry 3 "$URL" -o "$TMP/cssh.zip"
unzip -q "$TMP/cssh.zip" -d "$TMP"
XF="$(find "$TMP" -maxdepth 2 -name CSSH.xcframework -type d | head -1)"
[ -n "$XF" ] || { echo "CSSH.xcframework not found in archive" >&2; exit 1; }
rm -rf "$DEST/CSSH.xcframework"
cp -R "$XF" "$DEST/CSSH.xcframework"
echo "Installed $DEST/CSSH.xcframework"
