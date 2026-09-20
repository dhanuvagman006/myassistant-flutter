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

# The VPS is reachable three ways and which one works depends on the
# network: native IPv6 (Hostinger), the hostname (via NAT64 on IPv6-only
# networks), or the raw IPv4. Publishing used to die whenever the first
# choice was unroutable, so pick the first host that actually answers.
pick_vps() {
  for h in "root@[2a02:4780:63:17ab::1]" "root@api.hariassistant.tech" "root@200.141.9.112"; do
    bare="${h#root@}"; bare="${bare#[}"; bare="${bare%]}"
    if ssh -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new         "root@$bare" true >/dev/null 2>&1; then
      printf '%s' "root@$bare"
      return 0
    fi
  done
  echo "cannot reach the server on IPv6, hostname or IPv4 — check the network" >&2
  exit 1
}
VPS="$(pick_vps)"
echo "→ server: $VPS"
NS="myassistant"
APK="$(dirname "$0")/../build/app/outputs/flutter-apk/app-release.apk"

CODE="${1:?versionCode required (pubspec build number)}"
NAME="${2:?versionName required (e.g. 0.2.1)}"
shift 2
CHANGELOG_JSON="$(printf '%s\n' "$@" | python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().split("\n") if l.strip()]))')"

# THE CHANGELOG IS INTERPOLATED INTO A SINGLE-QUOTED `node -e` BLOCK, so a
# single apostrophe in it ends that quote and the whole script becomes
# invalid JavaScript. Build 36 failed exactly that way on the word
# "today's" — and because the failure happens INSIDE the ssh heredoc, the
# APK uploads fine, the registration dies, and the release silently does
# not happen. Base64 has no quotes, no backslashes and no dollar signs, so
# it survives every layer of quoting between here and the pod.
CHANGELOG_B64="$(printf '%s' "$CHANGELOG_JSON" | base64 | tr -d '\n')"

# THE RELEASE NOTES ARE RENDERED BY THE APP THE USER IS ALREADY RUNNING,
# not by the one being shipped — so a layout fix can never reach the people
# who need it. Build 36 shipped six long lines and pushed the "Update now"
# button off the bottom of the sheet on a Galaxy M15: the update was
# offered and could not be accepted. Keep them short enough for the oldest
# client still in the field.
CL_LINES=$#
CL_LONGEST=0
for line in "$@"; do
  n=${#line}
  [ "$n" -gt "$CL_LONGEST" ] && CL_LONGEST=$n
done
if [ "$CL_LINES" -gt 4 ] || [ "$CL_LONGEST" -gt 100 ]; then
  echo "REFUSING: $CL_LINES changelog lines, longest $CL_LONGEST chars." >&2
  echo "  Older clients clip the sheet and hide the install button." >&2
  echo "  Use at most 4 lines of at most 100 characters." >&2
  exit 1
fi
echo "→ changelog: $CL_LINES lines, longest $CL_LONGEST chars — fits"

[ -f "$APK" ] || { echo "no APK at $APK — run flutter build apk first" >&2; exit 1; }

# THE APK MUST DECLARE THE CODE WE ARE ADVERTISING. The app decides it is
# out of date by comparing /config's latestVersionCode against its OWN
# embedded versionCode. Publish 24 while the file still says 23 and every
# installed app downloads ~200 MB, installs it, restarts still saying 23,
# and starts over — a loop nothing breaks. Cheap to check, so check.
AAPT="$(ls "$HOME"/Android/Sdk/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)"
if [ -n "$AAPT" ]; then
  EMBEDDED="$("$AAPT" dump badging "$APK" 2>/dev/null |
    sed -n "s/^package:.*versionCode='\([0-9]*\)'.*/\1/p" | head -1)"
  if [ -n "$EMBEDDED" ] && [ "$EMBEDDED" != "$CODE" ]; then
    echo "REFUSING: the APK declares versionCode $EMBEDDED but you asked to publish $CODE." >&2
    echo "  Bump pubspec (version: x.y.z+$CODE) and rebuild, or publish $EMBEDDED." >&2
    exit 1
  fi
  echo "→ APK declares versionCode ${EMBEDDED:-?} — matches"
else
  echo "→ warning: aapt2 not found, could not verify the APK's versionCode" >&2
fi
echo "→ uploading $(du -h "$APK" | cut -f1) APK as build $CODE ($NAME)"
# rsync, not scp: a 135 MB upload over a hotspot uplink takes ~40 min and
# an interrupted one used to start over from byte zero. --partial --inplace
# resumes exactly where the last attempt died (2026-09-18: a kill at 78%
# cost half an hour). Falls back to scp only if rsync is missing.
SCP_HOST="$VPS"
case "$VPS" in *:*:*) SCP_HOST="root@[${VPS#root@}]";; esac
if command -v rsync >/dev/null 2>&1; then
  rsync -e ssh --partial --inplace "$APK" "$SCP_HOST:/tmp/hari-upload.apk"
else
  scp -q "$APK" "$SCP_HOST:/tmp/hari-upload.apk"
fi

ssh "$VPS" "
  set -e
  POD=\$(k3s kubectl get pods -n $NS -l app=myassistant-backend -o jsonpath='{.items[0].metadata.name}')
  k3s kubectl cp /tmp/hari-upload.apk $NS/\$POD:/app/data/hari-upload.apk
  rm -f /tmp/hari-upload.apk
  k3s kubectl exec -n $NS \$POD -- node -e '
    const up = require(\"./src/routes/appUpdate\");
    const changelog = JSON.parse(Buffer.from(\"$CHANGELOG_B64\", \"base64\").toString(\"utf8\"));
    up.publish({ tmpPath: \"/app/data/hari-upload.apk\", versionCode: $CODE, versionName: \"$NAME\", changelog })
      .then(m => { console.log(\"published:\", JSON.stringify({code: m.versionCode, name: m.versionName, size: m.size, sha256: m.sha256.slice(0,12)+\"…\"})); process.exit(0); })
      .catch(e => { console.error(\"publish failed:\", e.message); process.exit(1); });
  '
"
echo "→ verifying /config advertises build $CODE"
curl -fsS https://api.hariassistant.tech/config | python3 -c 'import json,sys; c=json.load(sys.stdin); print("config:", c.get("latestVersionCode"), c.get("latestVersionName"), c.get("apkUrl"))'
