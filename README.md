# lidrop

Drag a photo, video or file off your phone screen and drop it onto your Mac, as if the two screens were one. Free and open source (Apache-2.0).

**Status:** working demo. Android ↔ Mac and iPhone ↔ Mac, on one Wi-Fi or across networks, automatic discovery, both directions, any screen edge (learned from the drag direction). See [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Get it

| | Download | What you do |
|---|---|---|
| **Mac** | [lidrop-mac.zip](https://github.com/Steadfast11/lidrop/releases/latest/download/lidrop-mac.zip) | Open it. It moves itself to Applications and starts with your Mac. |
| **Windows** | [lidrop.exe](https://github.com/Steadfast11/lidrop/releases/latest/download/lidrop.exe) | Open it. It stays by the clock and starts with Windows. |
| **Android** | [lidrop-android.apk](https://github.com/Steadfast11/lidrop/releases/latest/download/lidrop-android.apk) | Install it and open it. |
| **iPhone** | Not downloadable yet | Build it from source, see [ios/README.md](ios/README.md). |

Then open lidrop on your phone. It finds your computer by itself, your computer asks **Allow** once, and that is all: from then on it connects whenever you open the app.

The apps are not signed yet, so the computer warns you once. **Mac:** if it says it cannot check the app, open System Settings → Privacy & Security and click **Open Anyway**. **Windows:** More info → Run anyway, then allow lidrop on Private networks. **Android:** allow your browser to install apps when it asks.

## Layout
- `mac/` — Mac menu-bar receiver (Swift, SwiftPM). Run: `cd mac && swift run`
- `android/` — Android app (Kotlin, Jetpack Compose)
- `ios/` — iPhone app (SwiftUI + Metal, see [ios/README.md](ios/README.md))
- `windows/` — Windows tray app, Android ↔ Windows (Rust, see [windows/README.md](windows/README.md))
- `docs/PROTOCOL.md` — wire protocol (the contract between the apps)

## Build it yourself
```bash
./scripts/build-release.sh   # dist/lidrop-mac.zip, dist/lidrop.exe, dist/lidrop-android.apk
```
Each platform has its own script next to it. The Windows app has not been tried on a real PC yet, see [windows/README.md](windows/README.md).

## Roadmap
Several phones and several files (in progress), one-button pairing with trust, Wi-Fi-less transports (Nearby / Wi-Fi Aware).

## License
Apache-2.0, see [LICENSE](LICENSE). Third-party parts: [THIRD_PARTY.md](THIRD_PARTY.md).
