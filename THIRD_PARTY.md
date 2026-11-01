# Third-party software

lidrop ships these prebuilt, unchanged, inside its apps:

- **dumbpipe** 0.40.1 (`mac/vendor/dumbpipe`, `android/app/src/main/jniLibs/arm64-v8a/libdumbpipe.so`, inside `lidrop.exe`), and the Rust crates it is built from, among them **iroh**. By n0, Inc. Licensed under MIT or Apache-2.0: <https://github.com/n0-computer/dumbpipe>

`ios/vendor/LidropTunnel.xcframework` is built from the same crates. `ios/tunnel/patches/` holds `netdev` and `netwatch` with small iOS fixes, under their own licences (see each folder).
