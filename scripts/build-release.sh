#!/bin/bash
# Everything a Release carries, in dist/: lidrop-mac.zip, lidrop.exe, lidrop-android.apk.
# The iPhone app is not here: Apple only lets it reach strangers through the App Store or TestFlight.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-mac-app.sh"
"$ROOT/scripts/build-windows-exe.sh"
"$ROOT/scripts/build-android-apk.sh"
ls -lh "$ROOT/dist/lidrop-mac.zip" "$ROOT/dist/lidrop.exe" "$ROOT/dist/lidrop-android.apk"
