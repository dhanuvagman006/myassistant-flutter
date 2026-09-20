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
set -euo pipefail
cd "$(dirname "$0")/.."
flutter build apk --release --target-platform android-arm,android-arm64
