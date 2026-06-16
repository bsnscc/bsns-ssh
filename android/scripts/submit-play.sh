#!/usr/bin/env bash
# Submit the release .aab to the Play internal track via the Google Play
# Developer API, authenticated through gcloud application-default credentials.
# Mirrors the bsns-mobile pipeline: no service-account JSON, uses graham@bsns.cc's
# ADC (already-linked Play account; quota project bsns-mobile).
#
# One-time setup (opens a browser once, then headless forever):
#   gcloud auth application-default login \
#     --scopes=https://www.googleapis.com/auth/androidpublisher
#   gcloud services enable androidpublisher.googleapis.com --project=bsns-mobile
#   gcloud auth application-default set-quota-project bsns-mobile
#
# The cc.bsns.ssh app must already exist in the Play Console (the API can't
# create a listing). Build the .aab first: ./gradlew :app:bundleRelease
#
# Usage:
#   android/scripts/submit-play.sh                       # default release .aab
#   android/scripts/submit-play.sh /path/to/app.aab
#   ANDROID_SUBMIT_TRACK=alpha ANDROID_SUBMIT_STATUS=draft ./submit-play.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

AAB_PATH="${1:-$ANDROID_DIR/app/build/outputs/bundle/release/app-release.aab}"
PACKAGE_NAME="cc.bsns.ssh"
TRACK="${ANDROID_SUBMIT_TRACK:-internal}"
RELEASE_STATUS="${ANDROID_SUBMIT_STATUS:-completed}"   # draft = stage in console instead
QUOTA_PROJECT="${ANDROID_QUOTA_PROJECT:-bsns-mobile}"  # linked Play project (shared)

API_BASE="https://androidpublisher.googleapis.com/androidpublisher/v3/applications/$PACKAGE_NAME"
UPLOAD_BASE="https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/$PACKAGE_NAME"

[[ -r "$AAB_PATH" ]] || { echo "✗ .aab not found at $AAB_PATH (build: ./gradlew :app:bundleRelease)" >&2; exit 1; }
command -v gcloud >/dev/null || { echo "✗ gcloud not found." >&2; exit 1; }
command -v jq >/dev/null || { echo "✗ jq not found (brew install jq)." >&2; exit 1; }

TOKEN="$(gcloud auth application-default print-access-token 2>/dev/null || true)"
[[ -n "$TOKEN" ]] || { echo "✗ No ADC token. Run: gcloud auth application-default login --scopes=https://www.googleapis.com/auth/androidpublisher" >&2; exit 1; }

AUTH="Authorization: Bearer $TOKEN"
QUOTA="X-Goog-User-Project: $QUOTA_PROJECT"
echo "  .aab:  $AAB_PATH ($(du -h "$AAB_PATH" | cut -f1))"
echo "  app:   $PACKAGE_NAME   track: $TRACK   status: $RELEASE_STATUS"

echo "→ Creating edit..."
EDIT_ID=$(curl -fsS -X POST -H "$AUTH" -H "$QUOTA" -H "Content-Type: application/json" -d '{}' \
  "$API_BASE/edits" | jq -r '.id // empty')
[[ -n "$EDIT_ID" ]] || { echo "✗ Failed to create edit (app exists in console? ADC has androidpublisher scope?)" >&2; exit 1; }

echo "→ Uploading .aab..."
VERSION_CODE=$(curl -fsS -X POST -H "$AUTH" -H "$QUOTA" -H "Content-Type: application/octet-stream" \
  --data-binary "@$AAB_PATH" "$UPLOAD_BASE/edits/$EDIT_ID/bundles?uploadType=media" | jq -r '.versionCode // empty')
[[ -n "$VERSION_CODE" ]] || { echo "✗ Bundle upload failed." >&2; curl -sS -X DELETE -H "$AUTH" -H "$QUOTA" "$API_BASE/edits/$EDIT_ID" >/dev/null 2>&1 || true; exit 1; }
echo "  versionCode: $VERSION_CODE"

echo "→ Assigning to '$TRACK'..."
curl -fsS -X PUT -H "$AUTH" -H "$QUOTA" -H "Content-Type: application/json" \
  -d "{\"releases\":[{\"versionCodes\":[\"$VERSION_CODE\"],\"status\":\"$RELEASE_STATUS\"}]}" \
  "$API_BASE/edits/$EDIT_ID/tracks/$TRACK" | jq -e '.error' >/dev/null 2>&1 \
  && { echo "✗ Track assignment failed." >&2; curl -sS -X DELETE -H "$AUTH" -H "$QUOTA" "$API_BASE/edits/$EDIT_ID" >/dev/null 2>&1 || true; exit 1; } || true

echo "→ Committing..."
for attempt in 1 2; do
  curl -fsS -X POST -H "$AUTH" -H "$QUOTA" "$API_BASE/edits/$EDIT_ID:commit" >/dev/null 2>&1 && break
  [[ "$attempt" == 1 ]] && { echo "  retrying commit in 5s..."; sleep 5; } || { echo "✗ Commit failed." >&2; exit 1; }
done
echo "✅ Submitted versionCode $VERSION_CODE to $TRACK ($RELEASE_STATUS). https://play.google.com/console"
