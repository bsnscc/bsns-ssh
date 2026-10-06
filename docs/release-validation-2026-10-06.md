# Release preparation validation — 2026-10-06

These results cover a working-tree preparation build, not a frozen submission
commit. The tree also contains shared-workspace work and build-number changes
from the preceding setup. Freeze and review the intended source before tagging.

## Automated checks

- Swift core: 122 XCTest cases and 44 Swift Testing cases passed (166 total).
- Android: 51 core tests and 8 app tests passed; no failures or skips.
- Android release lint: no errors, 21 warnings and 8 informational findings.
  Warnings include dependency/target-SDK age, static Activity references,
  backup configuration, and icon/resource suggestions. Play submission needs
  its own current target-SDK and device review; this pass targets the App Store.
- Android: signed release bundle built with OpenSSL 3.5.9 and patched libssh2
  1.11.1; mosh rebuilt against the updated headers.
- GitHub private vulnerability reporting: enabled and re-read as enabled.

- Apple native libraries: all five architecture builds passed; device, universal
  simulator, and universal macOS libraries assembled into the XCFramework.
- Live native transport: Ed25519 and ECDSA logins, exec, SFTP write/read,
  symlink creation, realpath, and missing-symlink error status passed against
  a temporary loopback SSH server using the rebuilt app library.
- Native Mac app: unsigned Debug build passed against the rebuilt libraries.

- iOS: signed Release archive passed for version 1.0, build 110, after the native
  rebuild. `codesign --verify --deep --strict` passed. App, SwiftTerm bundle, and
  notification-extension privacy manifests are present. The executable has no
  `mach_absolute_time` import; `stat`/`fstat` remain for the documented audit.
- Recipe syntax, manifest plist validation, and `git diff --check` passed.

## Local artifact record

Source base: `e436cce89c4ec202d0837115ef6bc3f5e7762146` plus the working-tree
changes described above. This is not an immutable release-source reference.

- iOS archive: `/private/tmp/bsns-release-readiness-patched.xcarchive`
- iOS executable SHA-256:
  `03c742e103940884f6ad73396ee3f0c38c7fa981cc254bd8faa67206c54b65da`
- Android bundle: `android/app/build/outputs/bundle/release/app-release.aab`
- Android bundle SHA-256:
  `f76a080423c9a2ff5df49bc896eaafb97df951d9b11a6c8aa9f4c60540cf6517`

Build/test logs are in `/private/tmp/bsns-release-*.log` on the build host.
Temporary artifacts are preparation evidence; make a durable release record
when freezing and submitting the candidate.

## External and device checks still pending

The review VM, physical iPhone/iPad acceptance, hardware-key signing, production
CloudKit notifications, privacy-label/manifest completion, policy publication,
and encryption classification are tracked in `launch-checklist.md`. No App Store
submission or public release was performed by this preparation pass.
