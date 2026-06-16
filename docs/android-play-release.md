# Android — Google Play release

## Build the upload artifact

```sh
cd android && ./gradlew :app:bundleRelease
# -> app/build/outputs/bundle/release/app-release.aab  (signed, arm64-v8a)
```

Signing is configured in `app/build.gradle.kts` from `android/keystore.properties`
(gitignored). The upload keystore is `android/app/upload-keystore.jks` (gitignored).
**Back up the keystore + its password.** With Play App Signing on (recommended,
default for new apps) the upload key is resettable via Google if lost, so this is
low-stakes, but keep them anyway.

## Licensing (GPLv3 on Play)

Unlike Apple's App Store — where mosh's `COPYING.iOS` exception is needed —
Google Play's terms don't carry the DRM/usage restrictions that conflict with
the GPL, so a GPLv3 app distributes on Play normally. We still provide the
corresponding source (the public repo). No special exception required.

## Done (engineering)

- Release signing config + signed AAB build, native lib bundled. ✅
- App id `cc.bsns.ssh`, minSdk 26, targetSdk 35, arm64-v8a.

## Manual / account steps (need the Play Console)

The bsns suite already has a Google Play Console developer account + a service
account (used for the mobile app's `.aab` uploads — see the Android deploy
pipeline notes). bsns-ssh is a **new app** under that same account.

1. **Create the app** in Play Console (first time is manual): name, default
   language, app/game = app, free/paid = free. Enable **Play App Signing**.
2. **Internal testing track** → upload `app-release.aab`. Either drag it into
   the console, or use the API submit script (same mechanism as bsns-mobile —
   gcloud **application-default credentials**, no service-account JSON):

   ```sh
   cd android && ./gradlew :app:bundleRelease
   android/scripts/submit-play.sh                 # uploads to the internal track
   ```

   `submit-play.sh` authenticates with graham@bsns.cc's ADC (quota project
   `bsns-mobile`, which is already linked to the Play account) and drives the
   Play Developer API directly (create edit → upload bundle → assign track →
   commit). Prerequisites:
   - **ADC with the androidpublisher scope** (one-time, opens a browser):
     `gcloud auth application-default login --scopes=https://www.googleapis.com/auth/androidpublisher`
   - The **`cc.bsns.ssh` app exists in the Play Console** (the API can't create a
     listing — create it once under the same developer account as `cc.bsns.mobile`).

   (We deliberately do *not* use a Play service-account JSON — the suite never set
   one up; the mobile pipeline uses user ADC, and this mirrors it.)
3. **Store listing**: short + full description, app icon (512×512), feature
   graphic, phone screenshots, **privacy policy URL**.
4. **App content**: content rating questionnaire, target audience, and the
   **Data safety** form — our strong story: *no data collected, no data shared*
   (the only network traffic is the user's own SSH + chosen sync). That matches
   the product's whole pitch and is the easiest possible data-safety declaration.

## Pre-public cleanup (before a real listing, not internal testing)

- Connect form defaults (`10.0.2.2` / `tester`) and the password-install spike
  (`tester`/`testpw`) are demo scaffolding — remove/neutralize for release.
- Real VT terminal widget (Termux terminal-view) before public, not just the
  ANSI-stripped text view.
- R8/minify: add a keep rule for `KeystoreSigner.sign` (called from native by
  name) before enabling minification.
- App icon / branding assets (the `bsns.$_` mark).
