#!/bin/bash
# Builds ios/vendor/LidropTunnel.xcframework from ios/tunnel (device + Apple-silicon simulator). Needs Rust: rustup target add aarch64-apple-ios aarch64-apple-ios-sim
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/ios/tunnel"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim
rm -rf "$ROOT/ios/vendor/LidropTunnel.xcframework"
mkdir -p "$ROOT/ios/vendor"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/liblidrop_tunnel.a -headers include \
  -library target/aarch64-apple-ios-sim/release/liblidrop_tunnel.a -headers include \
  -output "$ROOT/ios/vendor/LidropTunnel.xcframework"
du -sh "$ROOT/ios/vendor/LidropTunnel.xcframework"
