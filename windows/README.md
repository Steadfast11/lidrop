# lidrop for Windows

Drag a photo, video or file off the Android phone and it lands on the PC; drag a file from Explorer to the screen edge and it lands on the phone. The Android app needs no change: to it, this is a Mac. See [docs/PROTOCOL.md](../docs/PROTOCOL.md).

`lidrop.exe` is one file with no installer. It starts with no window, puts one small icon by the clock (a ring, or a disc while a phone is connected) and saves to `Downloads\lidrop`.

## Run it

Double-click `lidrop.exe`, wherever it landed. It copies itself to `%LOCALAPPDATA%\lidrop`, restarts from there, starts with Windows from then on and says so once. Windows 10 (1703) or later, 64-bit.

Two things Windows asks the first time, because the exe is not signed:

1. **SmartScreen:** "Windows protected your PC". Choose More info, then Run anyway.
2. **Firewall:** allow lidrop on Private networks. Without it the phone cannot find the PC on the Wi-Fi. Pairing still works with the tray menu's "Copy pairing code" pasted into "Enter pairing code" on the phone, because the tunnel goes outward.

The tray menu has the same items as the Mac's: connected phones, `IP:7777`, Copy pairing code, Open Downloads\lidrop, Launch at login, Quit.

The first drag from the phone teaches lidrop which side the phone sits on, and files dragged to that edge go to the phone. Until then that edge is the right one.

## Build it

On a Mac or Linux, with Rust and mingw-w64 (`brew install mingw-w64`):

```bash
./scripts/build-windows-exe.sh
```

This runs the tests, builds `dumbpipe` 0.40.1 from crates.io source the first time, puts it inside the exe and writes `dist/lidrop.exe`. Nothing comes from GitHub.

On a Windows PC with Rust, build `dumbpipe` the same way, put it at `windows\vendor\dumbpipe.exe` and run:

```bash
cargo build -p lidrop --release
```

With no `vendor\dumbpipe.exe` the exe still builds, and looks for `dumbpipe.exe` beside itself; with neither, it works on the local network only.

## Test it

Everything but the Win32 shell runs on any OS:

```bash
cargo test -p lidrop-core
```

`core/tests/fake_phone.rs` is a fake phone on a real socket, speaking what `Net.kt`, `Drag.kt` and `Receiver.kt` speak, in both directions.

Two more stand-ins, for trying things by hand:

```bash
cargo run -p lidrop-core --example headless -- --port 7777 --mdns
```

```bash
python3 tools/fake_phone.py --ceremony
```

`headless` is the core with no windows, printing one line for everything the app would have shown. `fake_phone.py` also runs on the PC against the real `lidrop.exe`, so the overlay, the Allow dialog and the toast can be tried with no phone. `--receive` waits for a drag from the PC. `cargo run --release -p lidrop-core --example preview -- FOLDER` writes what the overlay draws as PNGs.

## Why Rust

Goal: one `.exe` with no installer and no runtime to install. C# needs the .NET runtime or a large self-contained bundle, and `dotnet` is not on the Mac this was written on. Rust gives a small static exe, was already there, and cross-compiles from a Mac, so the Windows code is at least compiled and linked here. The iroh tunnel is Rust too.

## How it is put together

- `core/`: the protocol, files, trust, tunnel, mDNS, the animation (`stage.rs`, `Overlay.swift`'s numbers in pixels), the drawing (`render.rs`) and the edge zone's rules (`zone.rs`). No Windows in it, so all of it is tested here.
- `app/`: the Win32 shell, kept thin. `tray.rs` the icon and startup, `overlay.rs` the click-through window, `dropzone.rs` Windows → phone, `ask.rs` the Allow dialog, `shell.rs` small questions for Windows.

Windows-specific decisions:

- **The overlay is drawn on the CPU** into a layered window, updating only the rectangle that changed. That is the most dependable way to get per-pixel transparency above everything, and the frames can be looked at on any OS. A wave takes about 2 ms to draw at 1080p. If it stutters at 4K, that is the first place to look.
- **Windows → phone needs a trick.** macOS has a drag pasteboard anyone can read; Windows keeps a file drag private to the window under it. So while the left button is held within 120 pt of the edge, a nearly invisible strip (24 pt) appears along that edge and takes part in drag and drop. It only exists mid-press, so it can never swallow a click, and it stays away while a full-screen app runs. The file's drag image disappears over the strip while the phone's tile takes over.
- **It only ever copies.** The drop reports `COPY`, so the source file is never deleted.
- **File names from the phone are not trusted.** Windows has more traps than macOS: `\`, `C:`, `a.txt:stream`, `CON`, `NUL.txt`, trailing dots. See `safe_name` in `store.rs`.
- **The tunnel dies with the app** through a job object, however the app dies. The Mac runs `pkill` at startup for the same reason.
- **`screen_mm`** comes from the monitor's raw DPI when that looks sane, else from the size Windows assumes.

Differences from the Mac, on purpose or for now:

- The Android app still says "Mac" in a few messages, because it cannot tell the difference.
- No light field (the Metal shader in `Effects.swift`) and no frosted desktop: the tile, the lens, the wave and a soft glow at the edge. No shelf: a quiet toast says "Saved", and clicking it shows the file in Explorer.
- A video is saved correctly but cannot be played while it arrives. The tooltip shows the percentage.
- Several files or a folder go to the phone as one zip, like the Mac's, but with `size: -1`, because the zip's size is not known until commit.
- The tile of a zip shows the first item's picture, with no count badge.
- Dropping past the edge onto a second monitor does not send.

## Verified, and not

Verified on a Mac: the core against the fake phones, the real iroh tunnel end to end with Mac `dumbpipe` binaries, mDNS seen by macOS's own resolver, the exe compiled and linked for Windows, importing only system DLLs, and the drawing by eye from PNGs.

Never yet run on Windows, so the first run on a real PC should check, in this order:

1. The exe starts, the icon appears, and there is no console window.
2. The firewall prompt appears, and Android finds the PC by name.
3. The Allow dialog comes to the front.
4. The tile overlay: click-through, above everything, right size on a high-DPI screen, smooth at 4K.
5. The tunnel: `dumbpipe.exe` starts hidden, no antivirus objects to it being unpacked into `%LOCALAPPDATA%\lidrop`, and the tray's "Copy pairing code" lights up.
6. Windows → phone: the strip catches a drag from Explorer, and the thumbnail is right.
7. Quit leaves no `dumbpipe` process behind.
