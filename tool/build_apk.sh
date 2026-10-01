#!/usr/bin/env bash
# Build the release APK for REAL PHONES ONLY.
#
# Always build through this script (or copy its flag): plain
# `flutter build apk --release` bundles x86_64 as well — that ABI exists
# only on emulators, and with onnxruntime + webrtc native libs it added
# ~55 MB of dead weight to every download. The gradle abiFilters entry
# does NOT stop it: the Flutter gradle plugin overrides abiFilters with
# its own target-platform list, so the trim must happen on the flutter
# command line.
#
#   tool/build_apk.sh            → build/app/outputs/flutter-apk/app-release.apk
#   tool/build_apk.sh --phone    → the same, arm64 only: for installing on
#                                  the owner's phone (half the native work
#                                  and about half the APK, so the build and
#                                  the install are both quicker). Releases
#                                  for testers keep both ARM ABIs.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGETS="android-arm,android-arm64"
if [ "${1:-}" = "--phone" ]; then
  TARGETS="android-arm64"
  echo "→ phone build: arm64 only (not for publishing)"
fi

# APP CHECK DEBUG TOKEN (2026-09-29). Firebase AI Logic refuses requests
# without App Check from 2026-11-02, and these sideloaded (App Distribution)
# builds cannot use Play Integrity: they carry the debug token the owner
# registered in the Firebase console (App Check -> Apps -> Manage debug
# tokens). It lives in the git-ignored android/app-check-debug-token.txt
# and is compiled in as a dart-define (lib/ai/identity.dart). Never commit
# it, never print it.
TOKEN_FILE="android/app-check-debug-token.txt"
DEFINES=()
if [ -f "$TOKEN_FILE" ]; then
  APP_CHECK_DEBUG_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
  if [ -n "$APP_CHECK_DEBUG_TOKEN" ]; then
    DEFINES+=("--dart-define=APP_CHECK_DEBUG_TOKEN=$APP_CHECK_DEBUG_TOKEN")
    echo "→ App Check: debug token compiled in (from $TOKEN_FILE)"
  else
    echo "→ warning: $TOKEN_FILE is empty — no App Check debug token in this build" >&2
  fi
else
  echo "→ warning: no $TOKEN_FILE — this build has no App Check debug token," >&2
  echo "  so Firebase AI Logic will refuse it once App Check is enforced." >&2
fi

flutter build apk --release --target-platform "$TARGETS" \
  ${DEFINES[@]+"${DEFINES[@]}"}
