# App Store draft status

The iOS 1.0 record is saved in App Store Connect as **Prepare for Submission**.
It has not been submitted. Release is set to **Manual**. The existing base price
was verified as zero.

## Saved in App Store Connect

- Revised English description, promotional text, subtitle, and keywords from
  `store-listing.md`.
- Support link to the repository's issue tracker. Marketing link to the SSH
  repository until a dedicated product page is available.
- Dedicated SSH review account details in the private reviewer fields, with the
  expected host-key fingerprint and basic connection instructions.
- Review notes explicitly state that public TCP 443 access is awaiting the
  Lightsail rule and must be tested before submission.
- Existing reviewer contact fields preserved.
- Expired build 90 removed from the version; no build is currently selected.

The previous metadata was saved privately on the build Mac before editing.
No review credentials were added to this repository.

## Build identity warning

App Store Connect already has build 110, uploaded before the native-library and
privacy-manifest preparation changes. The later local validation archive also
uses build number 110. They are different artifacts.

Do not select the uploaded build 110 as evidence that the preparation fixes
shipped. Resolve the remaining release checks, freeze the intended source,
choose the next unused build number, build and upload that candidate, and select
its processed build explicitly. The local archive recorded in
`release-validation-2026-10-06.md` is preparation evidence only.

## Remaining before submission

- Open and externally test the review host's TCP 443 endpoint. Replace the draft
  blocker paragraph in the private review notes with the verified result.
- Finish the native privacy-API audit, encryption classification, privacy-label
  review, and publication of the corresponding privacy policy.
- Complete physical-device acceptance and any optional-feature review video.
- Upload and select the distinct, reviewed candidate described above.
- Review current screenshots: there are three each in the existing 6.7-inch
  iPhone, 6.1-inch iPhone, and 12.9-inch iPad screenshot sets. They have not been
  replaced or certified as matching the final candidate by this staging pass.
- Submit only on a later instruction. Keep manual release selected so approval
  and the public launch remain separate actions.

The marketing plan and draft founder introduction are in `launch-plan.md`.
