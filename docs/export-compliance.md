# Encryption classification — release decision required

Checked against Apple's documentation on 2026-10-06. This is a technical inventory,
not a completed legal classification or proof of an exemption.

The existing iOS build declares `ITSAppUsesNonExemptEncryption = false`. Preserve
that setting pending a documented classification decision; successful TestFlight
processing does not establish that the declaration is correct.

## Inventory

- SSH/SFTP/forwarding: bundled libssh2 with bundled OpenSSL, not only OS-provided crypto.
- Mosh: bundled protocol and OCB implementation; Apple CommonCrypto supplies AES.
- Configuration encryption: PBKDF2 and AES-GCM; include the implementation on each platform.
- Pairing, signing, and sealed messages: inventory the key exchange, signatures,
  and authenticated encryption in `Sources/BsnsSSHCore`.
- Hardware/token and software keys: authentication signatures and key management.
- Apple networking/CloudKit: OS-provided transport encryption in addition to the above.

## Before public distribution

1. Answer App Store Connect's encryption questionnaire using this actual inventory
   and the countries selected for distribution. Do not treat "standard algorithms"
   or "open source" alone as proof that no documentation is required.
2. Record the applicable exemption or classification, its basis, and the responsible
   account holder's decision. Obtain qualified advice if the classification is unclear.
3. Complete any required US reporting/notification and territory-specific steps,
   including the French requirements if applicable. Record acknowledgements without
   committing account credentials or sensitive correspondence.
4. Set the plist flag and any required export-compliance code to match the outcome;
   provide the documentation Apple requests before submitting the final build.

Decision: **pending**. No export classification has been changed in this release pass.

Sources:
- https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance
- https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations
