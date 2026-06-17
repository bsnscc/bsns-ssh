# Launch checklist — bsns.SSH first public release

The ordered gates from "review passed" to "live on both stores." Engineering is
essentially done; most of what's left needs a device or a store-console account.
Check items off in order — each phase assumes the previous one passed.

Current version: **1.0** (iOS build `46` / `CURRENT_PROJECT_VERSION`, Android
`versionName 1.0` / `versionCode 15`). The repo is already public and pushed
(HEAD ~`c97d46e`); the remaining open items are device/store gates, not code.

Detail docs this references:
- Android build/console steps → [`android-play-release.md`](android-play-release.md)
- No-telemetry proof → [`no-telemetry-verification.md`](no-telemetry-verification.md)
- Store copy + shot-list → [`store-listing.md`](store-listing.md)
- Licenses / disclosure → [`../THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md), [`../SECURITY.md`](../SECURITY.md)

---

## Phase 0 — Code freeze & verify

- [x] All review findings closed; branch green.
- [x] iOS: `swift test` + `xcodebuild … build` pass.
- [x] Android: `:core:test`, `:app:testDebugUnitTest`, `:app:lintRelease`,
      `:app:bundleRelease` pass (native prereqs built per `android/README.md`).
- [x] Branch pushed; repo is public (`bsnscc/bsns-ssh`) at HEAD ~`c97d46e`.

## Phase 1 — Trust gates (do not ship the marketing claims without these)

- [ ] **No-telemetry capture on a release build**, on a real iOS device
      (`rvictl` + `tcpdump`) and a clean Android emulator. Exercise launch →
      idle → connect → SFTP → background → foreground. Confirm PASS criteria in
      `no-telemetry-verification.md`; commit the destination summary next to
      `no-telemetry-evidence-2026-06-16.md`.
- [ ] **Privacy policy** published at `https://tools.bsns.cc/open-source/privacy`
      (mirror of the repo's [`../PRIVACY.md`](../PRIVACY.md)) and linked from both
      listings. Keep it distinct from the SaaS `bsns.cc/privacy`; confirm it
      matches the "Data Not Collected" label.
- [x] Repo flipped public (`gh repo edit bsnscc/bsns-ssh --visibility public`).
- [ ] **GPLv3 source availability**: confirm the public repo matches exactly what
      ships (the App Store/Play binary's corresponding source) at the tagged
      release commit.
- [ ] `SECURITY.md` disclosure path works (GitHub "Report a vulnerability"
      enabled on the repo settings).

## Phase 2 — Store assets

- [ ] Screenshots on real devices, dark mode, per the shot-list in
      `store-listing.md` — **live-terminal hero first**. Sizes: iPhone 6.9"+6.5",
      iPad 13", Android phone + tablet. No real hostnames/keys/tokens on screen.
- [ ] Verify the **app icon is legible at launcher size** on a real home
      screen / launcher before using it for store assets.
- [ ] Listing copy pasted from `store-listing.md` (name, subtitle/short desc,
      keywords, description, what's-new) into both consoles.

## Phase 3 — Legal / account prerequisites

- [ ] App Store Connect: app record created; privacy labels = Data Not Collected;
      encryption set to exempt (`ITSAppUsesNonExemptEncryption: false` is already
      in `project.yml`).
- [ ] Play Console: Data safety form = no data collected/shared; GPLv3 handling
      per `android-play-release.md` § Licensing; content rating, target audience,
      and the remaining manual console steps in that doc.

## Phase 4 — Build & submit

- [x] Version set to **1.0**: `MARKETING_VERSION 1.0` + `CURRENT_PROJECT_VERSION 46`
      in `app/project.yml`; `versionName 1.0` + `versionCode 15` in
      `android/app/build.gradle.kts`.
- [ ] iOS: archive the **Release** config, upload to App Store Connect, submit
      for review (TestFlight first if you want a final on-device pass).
- [ ] Android: `./gradlew :app:bundleRelease` → upload the signed `.aab`, roll
      out to internal testing, then production review.
- [ ] Tag the release commit `v1.0` once both artifacts are uploaded.

## Phase 5 — After approval

- [ ] Confirm repo is public and source matches the approved builds.
- [ ] Announce (operator-founder voice; the app is a bsns.cc brand vehicle —
      lead with privacy/hardware-keys/no-telemetry, not a feature list).
- [ ] Watch the `SECURITY.md` advisory inbox and store reviews for the first
      days.

---

_First impression is one-shot: Phase 2's hero screenshot and the icon's
launcher legibility carry the listing — don't ship them rushed._
