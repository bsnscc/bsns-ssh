#!/usr/bin/env bash
# DEPRECATED. We no longer fetch a prebuilt xcframework — that one linked
# OpenSSL 1.1.1w (EOL). The CSSH xcframework is now built from source by
# build-cssh.sh (libssh2 1.11.0 on OpenSSL 3.5.1, pinned + sha256-verified).
#
# Run instead:
#   vendor/build-cssh.sh
set -euo pipefail
echo "fetch-cssh.sh is deprecated; run vendor/build-cssh.sh instead." >&2
exec "$(dirname "$0")/build-cssh.sh"
