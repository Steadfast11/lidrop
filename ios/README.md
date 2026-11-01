# lidrop for iPhone

SwiftUI + Metal app (iOS 17+, bundle id `dev.lidrop.ios`). It does what the Android app does: finds the Mac over Bonjour (`_lidrop._tcp`), Allow once and remembered, the iroh tunnel across networks, the connect ceremony, the light, photos/videos/files, several files at once, a video the Mac can play while it arrives, Mac→phone, and sending from any app's Share Sheet. Files dragged from the Mac land in Files app → On My iPhone → lidrop, and in the app's Received tab.

## Install on your iPhone — 5 steps

1. Open `ios/Lidrop.xcodeproj` in Xcode (re-create it any time with `xcodegen generate` in `ios/`).
2. Xcode → Settings → Accounts → add your Apple ID. Click the **Lidrop** project, then for **both** targets, **Lidrop** and **LidropShare**: *Signing & Capabilities* → tick *Automatically manage signing* → *Team*: your "Personal Team".
   If Xcode says a bundle id or the App Group is taken, use your own: `dev.lidrop.ios.yourname` for Lidrop, `dev.lidrop.ios.yourname.share` for LidropShare, and `group.dev.lidrop.ios.yourname` in both *App Groups* boxes and in `APP_GROUP` (`Lidrop/Common.swift`).
3. Plug the iPhone in, unlock it, tap *Trust*. Enable *Settings → Privacy & Security → Developer Mode* (restart when asked).
4. In Xcode pick your iPhone as the run destination and press ▶︎ Run.
5. First launch: on the iPhone go to *Settings → General → VPN & Device Management → your Apple ID → Trust*. Open lidrop, allow *Local Network* and *Photos*. With the computer app running on the same Wi‑Fi, it connects by itself: click *Allow* on the computer once, and it never asks again.

Free personal-team builds expire after 7 days; re-run from Xcode to renew.

Not on the same Wi‑Fi at first pairing: wait 15 seconds until it says "Open lidrop on your computer", then paste the menu's "Copy pairing code" into "Use pairing code".

## Build for the simulator

```
cd ios && xcodegen generate
xcodebuild -project Lidrop.xcodeproj -scheme Lidrop -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```
Apple-silicon simulators only. Test hooks: launch with `-connect HOST[:PORT]` (or a pairing code) to skip discovery, `-skipGate YES` to skip the connect ceremony, `-look A|B|C`, `-fxdemo YES` to play the light with no Mac.

## The tunnel library

iOS cannot start the `dumbpipe` binary Android runs, so `ios/tunnel` (Rust) is the same `connect-tcp` as a library, prebuilt in `ios/vendor/LidropTunnel.xcframework`. Only needed after changing it:
```
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
./scripts/build-ios-tunnel.sh
```
`Cargo.lock` keeps iroh on the version the Mac's `dumbpipe` 0.40.1 was built with. `tunnel/patches/` holds `netwatch` and `netdev` with small iOS fixes: `libc` hides the route-socket names on iOS.

## Where it differs from Android

- **Share Sheet:** iOS shows the throw in its own sheet, not a see-through window over the source app, and there is no row of people/devices for it. A tile cannot leave through the top of that sheet.
- **Background:** iOS suspends the app, so the link is dropped when it leaves the screen and comes back on return. A transfer in flight keeps the short time iOS allows.
- **Videos** are copied out of Photos first (from iCloud if needed), so streaming starts after that copy.
- **Physical size** (`tile_mm`, `screen_mm`) assumes ~460 ppi (@3x) or 326 ppi (@2x, e.g. XR); iOS does not expose the real value.

## Sources

`Net.swift` (framing, hello), `Connector.swift` (Bonjour, tunnel choice), `Tunnel.swift`, `Drag.swift` (tile geometry + send), `Receiver.swift` (Mac→phone), `Light.swift` + `Shaders.swift` (the light, compiled at launch so building needs no Metal toolchain), `Overlay.swift` (UIKit tile and light layer), `Pair.swift` (ceremony), `Views.swift` (UI), `Tiles.swift` (shared tile + UIKit long-press), `Model.swift` (one connection), `LidropShare/` (Share extension, reuses the above with role `share`).
