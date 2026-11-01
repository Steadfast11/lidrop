#!/bin/sh
# Builds the lidrop Android APK to dist/lidrop-android.apk (debug-keystore signed, so it installs with `adb install -r`).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/android"
./gradlew assembleDebug -q
mkdir -p "$ROOT/dist"
cp app/build/outputs/apk/debug/app-debug.apk "$ROOT/dist/lidrop-android.apk"
echo "$ROOT/dist/lidrop-android.apk"
