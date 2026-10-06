# First public App Store release — 2026-10-06

This checklist supersedes the June checklist. Do not carry old checked boxes
forward as evidence for a new build. The repository is public; the candidate
commit, version, archive, and device results must identify the same artifact.
Android and native Mac distribution have separate release checks.

## Completed preparation

- [x] Correct the repository privacy policy for CloudKit/push, relay metadata,
      encrypted software-key export, diagnostics, and voluntary support reports.
- [x] Replace obsolete store copy and prepare SSH-on-443 review notes.
- [x] Add first-connection and shared-workspace documentation.
- [x] Add app, notification-extension, and vendored terminal privacy manifests.
- [x] Remove the unsupported assumption that standard encryption proves exemption;
      record the classification decision still needed in `export-compliance.md`.

## Required before submission

- [ ] Freeze a reviewed candidate commit, including all intended source and host
      helper files. Keep unrelated concurrent work out of the release artifact.
- [ ] Record the version/build and exact source commit in the release record.
- [ ] Pass core tests and signed Release archive validation for that candidate.
- [ ] Inspect bundled manifests and complete `privacy-manifest-audit.md`.
- [ ] Resolve encryption classification and align the plist/store answers.
- [ ] Publish the updated privacy policy at the listing's URL; verify its contents.
- [ ] Reconcile App Store privacy answers with the release's actual data flows.
- [x] Review SSH/crypto advisories and update pinned build inputs; see
      `native-dependency-audit-2026-10-06.md`.
- [ ] Ensure corresponding source and dependency license texts are available for
      the exact distributed artifact; verify the mosh App Store exception applies.

## Review environment

- [ ] Provision the dedicated VM and expose real SSH on TCP 443, with no VPN,
      VPN, or source-IP allowlist required for review.
- [ ] Use an unprivileged review account; no production credentials/data or sudo.
      Give it sample files, tmux, and a harmless local service for forwarding.
- [ ] Set credentials privately in App Store Connect. Record the expected host-key
      fingerprint there. Keep the account available through review and follow-up.
- [ ] Verify password SSH and SFTP from outside the developer's network.
- [ ] Test optional key installation and mosh separately; document UDP requirements.
- [ ] Complete the placeholders in `store-listing.md` and attach a demonstration
      video matching the submitted build. Confirm every claim against the VM.

## Clean-device acceptance

Use a clean physical iPhone and an iPad, not only an existing configured install.
Record build, OS, steps, actual result, and any limitation for each item.

- [ ] First launch, password SSH on 443, host trust, key setup, and reconnect.
- [ ] Changed-host-key refusal and wrong-credential errors.
- [ ] SFTP upload/download, local forwarding, and supported jump-host behavior.
- [ ] Keyboard show/hide, search, rotation, hardware keyboard, and readable layouts.
- [ ] Background/foreground, Wi-Fi/cellular changes, and optional mosh recovery.
- [ ] Import older configuration, encrypted sync between current devices, and
      hardware-key non-exportability. Finish the new workspace sync exercise.
- [ ] Cloud relay on a production entitlement/schema, extension delivery while
      backgrounded, notification denial, offline expiry, and iCloud unavailable.
- [ ] Optional hardware-key features demonstrated on real hardware.
- [ ] Redacted network-capture evidence for optional features and baseline launch.
- [ ] Screenshots and accessibility claims match demonstrated release behavior.

## Store and support

- [ ] Verify privacy/support URLs, review contact, price, availability, age rating,
      and any applicable account/trader requirements in App Store Connect.
- [x] Enable and verify the private vulnerability-reporting route in `SECURITY.md`.
- [ ] Create a tagged source release with build instructions and known limitations.
- [x] Set manual release for the staged iOS version; see
      `app-store-draft-2026-10-06.md` for the verified draft state.
- [ ] Submit the verified build. Record approval and release separately.

Current blockers are deliberately unchecked. A successful upload or simulator
build is not evidence that physical-device, policy, or review-access gates passed.
