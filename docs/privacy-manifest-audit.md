# Privacy manifest audit — 2026-10-06

## Bundled declarations

| Target | Required-reason APIs | Reason | Use |
| --- | --- | --- | --- |
| iOS/iPadOS and Mac app | UserDefaults / AppStorage | CA92.1 | The app's own preferences |
| iOS/iPadOS and Mac app | File metadata | C617.1 | Size of the app's local diagnostic log |
| Vendored SwiftTerm resource bundle | UserDefaults | CA92.1 | This app's predictive-input preference |
| Vendored SwiftTerm resource bundle | stat/fstat | C617.1 | In-container terminal image payload metadata on iOS |
| Notification extension | None identified in extension source/core dependencies | — | Keychain, CloudKit and notification APIs |

Manifests declare no tracking or tracking domains. Empty collected-data arrays
reflect the existing developer-collection position; the final App Store label
still needs the CloudKit metadata assessment below. Do not infer that an empty
array means the app makes no network connections.

The legacy `mach_absolute_time` fallback was disabled in the Apple mosh config.
Every supported Apple OS provides the preferred `clock_gettime` path, and the
existing wall-clock fallback remains. Mosh serializes protocol timestamps, so
we do not assert that the old system-boot-time-derived values stayed on device.
The build must confirm that this fallback no longer contributes that import.

## Outstanding release checks

- Inspect the final archive, including app extensions, resource bundles, and
  native dependencies, for manifests and required-reason API imports. A symbol
  scan is a screening tool, not proof of every runtime path or SDK behavior.
- Review OpenSSL/libssh2 native file-metadata uses against Apple's approved
  reasons; do not assume an app-container reason covers system/device files.
- For a future Mac App Store submission, separately review terminal file/shared
  memory image handling outside the sandbox and the applicable metadata reasons.
  This pass targets iOS App Store readiness, not Mac App Store certification.
- Classify the optional CloudKit relay's ciphertext, random device identifiers,
  message type, record identifiers, timestamps, and push metadata under Apple's
  current privacy-label definitions. End-to-end encryption does not make routing
  metadata disappear. Confirm the final questionnaire and manifests agree.
- Publish the updated policy, then check its live content, not just HTTP status.
- Capture the release build's network destinations for the feature matrix in
  `no-telemetry-verification.md`.

## Native symbol screening

The rebuilt iOS static archive still references file-metadata APIs in OpenSSL's
configuration, random-file/device, certificate-directory, and file-store objects.
In particular, the random-device path can inspect `/dev/urandom`, which is not an
app-container file. Do not close the native review just because C617.1 appears
in the app manifest. Establish which paths survive linking and execute, and
resolve their declaration or build configuration before submission. libssh2's
remote SFTP stat operations are protocol messages, not local filesystem API use.

## References

- https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype
- https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- https://developer.apple.com/app-store/app-privacy-details/

Reason codes were checked against Apple's documentation on the date above.
