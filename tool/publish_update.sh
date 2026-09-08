#!/usr/bin/env bash
# Publish the current release APK to the self-update channel.
#
#   tool/publish_update.sh <versionCode> <versionName> "<changelog line>" ["<line 2>" ...]
#
# Copies build/app/outputs/flutter-apk/app-release.apk to the VPS, into
# the backend pod, and registers it via routes/appUpdate.publish() — after
# which every installed app sees "Update available" on next launch
# (GET /config → latestVersionCode/apkUrl/apkSha256, GET /app/latest.apk).
#
# versionCode MUST match the pubspec build number the APK was built with
# (version: x.y.z+N → N) and be greater than what users are running.
set -euo pipefail

VPS="root@200.141.9.112"
NS="myassistant"
APK="$(dirname "$0")/../build/app/outputs/flutter-apk/app-release.apk"

CODE="${1:?versionCode required (pubspec build number)}"
NAME="${2:?versionName required (e.g. 0.2.1)}"
shift 2
CHANGELOG_JSON="$(printf '%s\n' "$@" | python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().split("\n") if l.strip()]))')"

[ -f "$APK" ] || { echo "no APK at $APK — run flutter build apk first" >&2; exit 1; }
echo "→ uploading $(du -h "$APK" | cut -f1) APK as build $CODE ($NAME)"
scp -q "$APK" "$VPS:/tmp/hari-upload.apk"

ssh "$VPS" "
  set -e
  POD=\$(k3s kubectl get pods -n $NS -l app=myassistant-backend -o jsonpath='{.items[0].metadata.name}')
  k3s kubectl cp /tmp/hari-upload.apk $NS/\$POD:/tmp/hari-upload.apk
  rm -f /tmp/hari-upload.apk
  k3s kubectl exec -n $NS \$POD -- node -e '
    const up = require(\"./src/routes/appUpdate\");
    up.publish({ tmpPath: \"/tmp/hari-upload.apk\", versionCode: $CODE, versionName: \"$NAME\", changelog: $CHANGELOG_JSON })
      .then(m => { console.log(\"published:\", JSON.stringify({code: m.versionCode, name: m.versionName, size: m.size, sha256: m.sha256.slice(0,12)+\"…\"})); process.exit(0); })
      .catch(e => { console.error(\"publish failed:\", e.message); process.exit(1); });
  '
"
echo "→ verifying /config advertises build $CODE"
curl -fsS https://api.hariassistant.tech/config | python3 -c 'import json,sys; c=json.load(sys.stdin); print("config:", c.get("latestVersionCode"), c.get("latestVersionName"), c.get("apkUrl"))'
