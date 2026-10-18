#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
xcodegen generate

# Pass the build number as an Xcode setting. Editing the built Info.plist from a
# script phase races Xcode's own plist processing on incremental builds.
build_number="$(date -u +%Y%m%d%H%M%S)"
configuration="${BSNS_MAC_CONFIGURATION:-Debug}"
xcodebuild -project BsnsSSHMac.xcodeproj -scheme BsnsSSHMac \
  -configuration "$configuration" -destination 'platform=macOS' \
  CURRENT_PROJECT_VERSION="$build_number" "$@" build
