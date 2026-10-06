#!/usr/bin/env bash
# DEPRECATED. We no longer fetch a prebuilt xcframework — that one linked
# OpenSSL 1.1.1w (EOL). The CSSH xcframework is now built from source by
# build-cssh.sh (pinned, checksum-verified libssh2 + OpenSSL with security patches).
#
# Run instead:
#   vendor/build-cssh.sh
set -euo pipefail
echo "fetch-cssh.sh is deprecated; run vendor/build-cssh.sh instead." >&2
exec "$(dirname "$0")/build-cssh.sh"
