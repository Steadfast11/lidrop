# lidrop demo protocol v0.2 (phone → Mac drag, automatic side detection)

Demo scope: Android phone sits next to the Mac on ANY side. No setting, no menu choice: **the side is inferred from the drag itself**. The user drags the tile toward the Mac; whichever phone edge the tile leaves through, the tile enters the Mac through the OPPOSITE edge. Everything marked `DEMO-CONST` may be a constant.

## Edge model
`edge` (sent by the phone in `drag_move`) = the PHONE screen edge the tile is leaving through: `left | right | top | bottom` (as displayed, also in landscape).
The Mac entry edge is the opposite: phone `left` → Mac `right`; phone `right` → Mac `left`; phone `top` → Mac `bottom`; phone `bottom` → Mac `top`. Phone and Mac are assumed upright, same orientation, no mirroring.
`along` = finger position along that edge in reading direction: for phone `left`/`right` edges 0 = top → 1 = bottom; for phone `top`/`bottom` edges 0 = left → 1 = right. The Mac uses the same value along its entry edge.
The phone picks `edge` dynamically while dragging: the edge with the largest overhang (tile pushed furthest past it); use hysteresis so it does not flicker near corners. If overhang is 0 on all edges, send `edge` = the last used one (default `left`) with `overhang` 0.

## Connection
- Mac app listens on TCP **port 7777**, all interfaces, and advertises itself over Bonjour/mDNS as service type `_lidrop._tcp` (name = Mac's computer name, port 7777).
- Phone discovery (v0.3): the phone app finds Macs with Android `NsdManager` (`_lidrop._tcp`). It connects automatically when exactly one Mac is found and shows a tap-to-connect list when several are. It remembers the last Mac and reconnects automatically on app start and after a dropped connection. A manual IP field stays under an "Enter IP manually" fallback (for networks that block mDNS). The Mac menu bar still shows `IP:7777`.
- Tunnel: the Mac runs the bundled iroh `dumbpipe listen-tcp --host 127.0.0.1:7777` with a fixed key (`~/Library/Application Support/lidrop/tunnel.key`), so its ticket never changes. The phone runs `libdumbpipe.so connect-tcp --addr 127.0.0.1:17777 <ticket>` and speaks the same framing to that loopback port. Works across any two networks with internet, direct when the networks allow it, relayed when not, always end-to-end encrypted. It is the preferred path even on one Wi-Fi (QUIC measured about twice plain TCP on a weak link). The plain LAN path remains for first pairing and for a shared network with no internet.
- Pairing: first message is `hello` with a stable `id` and saved `token`. A known pair goes straight in. Otherwise the Mac shows Allow once, stores `{id: token}` in `trust.json`, and `welcome` returns `token` and `ticket` (`{"t":"ticket"}` if the ticket comes later; `{"t":"denied"}` on refusal). Nothing else is accepted before that. Not on the same Wi-Fi at first pairing: paste the Mac menu's "Copy pairing code" into "Enter pairing code" on the phone. Trust never expires.
- One phone at a time; a new connection from the same phone replaces the old one.

## Framing (both directions)
Each frame: `u32 big-endian length N` · `u8 type` · `N-1 bytes payload`.
- type `1` = JSON control message (UTF-8)
- type `2` = binary file chunk (raw bytes of the file currently being transferred; max 256 KiB per frame)
- type `3` = video block: `u32 BE block index` · up to 256 KiB. A single video is sent this way (`file_begin` has `"stream":true,"size":N,"mime":"…"`) so the Mac can play it while it arrives; `{"t":"want","id":"<uuid>","block":N}` from the Mac moves the phone's read position, which also serves camera videos that keep their index at the end.

## Control messages (JSON, field `t` is the type)
Phone → Mac:
- `{"t":"hello","name":"Galaxy S24","v":0}` — first message.
- `{"t":"drag_start","id":"<uuid>","name":"IMG_1.jpg","mime":"image/jpeg","size":123456,"thumb":"<base64 JPEG, the file's own shape, longest side 512>","tile_dp":192,"tile_mm":35.5,"screen_mm":[68.0,148.0]}` — `tile_mm` = physical tile size on the phone; `screen_mm` = phone screen width/height as displayed (swapped in landscape); the Mac may use them to draw the tile at the same physical size (fall back to `tile_dp` if absent).
- `{"t":"drag_move","id":"<uuid>","edge":"left|right|top|bottom","along":0.42,"overhang":0.0-1.0}`
  - `overhang`: fraction of the tile that has crossed the phone edge `edge` (0 = fully on phone, 1 = fully off the phone). Send at ≥ 60 Hz while dragging.
- `{"t":"drag_end","id":"<uuid>","commit":true|false}` — finger lifted. `commit` = `overhang >= 0.5`.
- If `commit` is true, then immediately: `{"t":"file_begin","id":"<uuid>"}`, N × frame type 2, `{"t":"file_end","id":"<uuid>"}`.

Mac → Phone:
- `{"t":"welcome","name":"MacBook Air","screen_mm":[302.0,196.0]}` — `screen_mm` is the Mac screen width/height; the phone uses it to draw the same dome
- `{"t":"saved","id":"<uuid>","path":"/Users/.../Downloads/lidrop/IMG_1.jpg"}`
- `{"t":"error","id":"<uuid>|null","msg":"..."}`
(There is no `edge` message from the Mac any more.)

## Mac behaviour
- On `drag_start`: prepare a floating tile (96×96 pt, rounded corners, shadow) showing `thumb`; hidden while `overhang == 0`.
- On `drag_move`: show the tile on the **main screen**, entering through the entry edge opposite to `edge`. Visible depth = `overhang * 96` pt. Entry edge right: tile left x = `screenMaxX − overhang*96`, vertical centre from `along` (0 top → 1 bottom; flip for AppKit coordinates). Entry edge left: tile right x = `screenMinX + overhang*96`, same vertical rule. Entry edge top: visible depth from the top of the screen, horizontal centre = `screenMinX + along*screenWidth`. Entry edge bottom: visible depth from the bottom, same horizontal rule. If the edge changes mid-drag, animate the tile out through the old edge and in through the new one. Animate smoothly (interpolate toward target, ~60 fps). Overlay is a borderless, click-through `NSPanel` above all windows, on all Spaces.
- On `drag_end` with `commit:false`: animate tile back out through the same edge and hide.
- On `drag_end` with `commit:true`: tile settles fully on screen; on `file_end` save to `~/Downloads/lidrop/<name>` (add ` (1)` etc. on collision), reply `saved`, reveal the file in Finder (select it), animate tile to a short "landed" state then fade out.
- Menu bar item (accessory app, no Dock icon) shows connection state and `IP:7777`, with menu items: "Open Downloads/lidrop", "Quit". No side-selection menu.

## Phone behaviour
- Screen 1: Mac IP field (default `DEMO_MAC_IP`) + Connect → shows Connected/Disconnected.
- Screen 2: grid of device photos/videos (MediaStore; request `READ_MEDIA_IMAGES` + `READ_MEDIA_VIDEO`). Long-press a cell → picks up a 96dp tile (thumbnail) that follows the finger. As the finger nears ANY screen edge the tile slides out through it: the finger stays on screen and drifts toward the tile's trailing end while the tile leaves, so a user can throw the tile off whichever side the Mac is on. The tile is drawn only inside the screen (the rest "continues" on the Mac). Show a subtle glow strip on the edge the tile is currently leaving through.
- Phone also has a "Pick file…" button (system file picker) that puts the chosen file in the same draggable tile.
- Send `drag_move` continuously; on release apply the commit rule; show a small "Sent ✓" toast on `saved`.
- Keep the screen on and the app in the foreground while connected.

## Share from other apps
`ShareActivity` is the share target (also a Direct Share target): a see-through window over the source app with its own connection. The file appears as a tile, the throw and light run there, and the window closes when `saved` arrives. The app itself never opens.

## Mac → phone drag (v0.4)
The user drags file(s) from Finder (or any app) toward the phone. Detection on the Mac: a global `NSEvent` monitor for `leftMouseDragged` / `leftMouseUp`; a file drag is in progress when `NSPasteboard(name: .drag)` holds file URLs and its `changeCount` changed since the mouse went down. First file only in v0.4.
Which Mac edge leads to the phone is LEARNED: the entry edge of the last phone→Mac drag (persist in UserDefaults; default `right`). When the cursor reaches within 24 pt of that edge the Mac starts the handoff; the native drag image stays under the cursor (the Mac cannot hide it).

Mac → Phone (JSON, same framing):
- `{"t":"mdrag_start","id":"<uuid>","name":"report.pdf","mime":"application/pdf","size":123456,"thumb":"<base64 JPEG 512x512 center-cropped, or file-type icon>","tile_mm":35.5,"edge":"right"}` — `edge` = the MAC edge being crossed; the phone tile enters through the OPPOSITE phone edge.
- `{"t":"mdrag_move","id":"<uuid>","along":0.42,"overhang":0.0-1.0}` — `along` = cursor position along the Mac edge in reading direction (same convention as the Edge model); `overhang` = how far the cursor has gone into the 24 pt edge zone (0 = at zone start, 1 = on the screen edge). Send at ≥ 60 Hz.
- `{"t":"mdrag_end","id":"<uuid>","commit":true|false}` — mouse released; `commit` = cursor was within 4 pt of the edge. If `commit`: `{"t":"file_begin","id":"<uuid>"}`, N × frame type 2 (≤ 256 KiB), `{"t":"file_end","id":"<uuid>"}`.
A zip (folder or several files) is only made on commit, so its size is not known at `mdrag_start`: it goes as `"size":-1`, at the top level and in `files[0]`, and the phone skips its size check. A real size that differs from the bytes sent makes the phone refuse the file.
Phone → Mac: `{"t":"saved","id":"<uuid>","path":"..."}` or `{"t":"error","id":"<uuid>","msg":"..."}` (same messages as the Mac sends for phone→Mac).

Phone behaviour: on `mdrag_start` draw a tile (192 dp, `thumb`, same visual as the picked-up tile) in a top overlay, entering through the edge opposite to the Mac `edge`, visible depth = `overhang` × tile size, centred on `along` mapped through the phone/Mac physical span (inverse of the Mac mapping). On `mdrag_end` commit:false animate out; commit:true settle fully, receive the file, save to the public `Download/lidrop/` folder (MediaStore Downloads on API 29+, collision-safe name), reply `saved`, show "Received ✓" with an Open action. A phone→Mac drag and a Mac→phone drag never run at the same time (ignore `mdrag_start` while the phone is dragging or sending).

## Several phones and several files (v0.5)
**Several phones on one Mac.** The Mac accepts any number of simultaneous phone connections (no more "a new connection replaces the old one"). Each connection has its own state; only one drag (either direction) runs at a time, a second `drag_start`/`mdrag_start` from another phone while one is active is ignored (reply `error` "busy"). Mac → phone target: the phone that most recently sent a `drag_start` (or, if none yet, the most recently connected one). The menu bar lists connected phones by their `hello` name.

**Picking up.** Wherever a tile is held, it flies to the middle of the screen and waits there; the finger then moves it relatively, 1.8× as fast, so every direction reads the same and an edge is in reach from anywhere. The same goes for a group.

**Group drag.** Selecting files is tapping them. Holding any tile while files are selected takes the whole group, that tile included: the selected tiles leave the grid and fan out behind the one in the hand, with a count, and throwing it sends them all. Letting go short of the edge keeps the selection.

**Several files / folders.** `drag_start` and `mdrag_start` may carry `"files":[{"name":"a.jpg","size":123,"mime":"image/jpeg"},…]` and `"count":N` (the top-level `name/mime/size` describe the first file, for old receivers). The tile shows a stack with a count badge. On commit the sender transfers the files one after another: for each index i, `{"t":"file_begin","id":"<uuid>","index":i}`, chunks, `{"t":"file_end","id":"<uuid>","index":i}`; the receiver answers `saved` per file (with `index`). A folder or multi-selection dragged from Finder on the Mac is sent as a single zip (`ditto -c -k --sequesterRsrc --keepParent`) named `<folder>.zip` / `Archive.zip`, not as a list.
Receivers that do not know `index` treat messages as index 0.

## Connect ceremony (v0.7)
Seen once. **A phone a computer has already allowed opens straight on the gallery** and connects behind it, every time, with no screen and no gesture of its own: discovery and the tunnel start with the app, the dot by the computer's name turns green. There is nothing to disconnect; the link follows the app.
The first time, the app opens on a gate: a dark screen and one drop of liquid glass, the computer's name above it. It dials at once by itself (tunnel or LAN), the computer asks Allow once, the drop fills with liquid and stops short of full until `welcome` arrives, and only then the wave plays. With several computers on the network the gate shows their names and waits for a tap. With none it keeps looking, and after 15 s says "Open lidrop on your computer" and offers the pairing code. "Don't Allow" stops the dialing, so the question never comes back on its own: a tap on the drop asks again, and so does leaving the app and returning. Files shared from another app connect without a gate.
Phone → Mac: `{"t":"pair","state":"hold","p":0.0-1.0}` about 30 times a second once connected, `{"t":"pair","state":"ping"}` among them, answered at once by `{"t":"pair","state":"pong"}`, then `{"t":"pair","state":"burst"}` or `{"t":"pair","state":"cancel"}`. `welcome` carries `"edge"`, the Mac edge the phone sits at, so both ends put the seam in the same place.
**One surface.** The lens and the wave are one object across the seam, the same formulas on every end (`GlassFX` on the Mac, `Pair.kt`, `Pair.swift`), in millimetres: lens radius `10 + 24p`, wave radius `0.66 · Mac width · (1 − e^(−t/0.3))`, centred on the seam, gone by t = 1 s. **One clock.** The Mac starts when `burst` arrives; the phone starts half the fastest ping after sending it. **One burst.** The ceremony has its own overlay mode on the Mac, not the drag light: only the first `burst` counts, and a `hold` still in flight cannot start another one. Colours stay out of it: white light on glass, and on the Mac the desktop frosts under the lens.

## Light effects v5 (visual spec, both ends; no protocol change) — REPLACES v1…v4
Target: a prismatic light leak with soft spectral shafts, bloom and a soft flash, judged against the drooop demo (stills in `.reference/light/`, gitignored, local only; `compare_v5.jpg` = reference, the live Mac looks and the phone looks side by side). Colour bands read as near vertical and the light gathers at the tile's height; nothing converges at or brightens along the top of the screen.
**One continuous light field, per pixel**, the same formula on both ends: Metal in `mac/Sources/lidrop/Effects.swift`, AGSL `RuntimeShader` in `android/.../Light.kt`. Keep the two in step, including the look table. All numbers below are for entry edge = right; the other edges mirror or rotate.
**Space.** Screen stretched to x 0…1.6 (entry edge at 1.6), y 0…1 down. `d` = distance from the entry point (x 1.6, y = tile position), kept round by scaling y with edge length / (inward length / 1.6).
**The single point.** O = (0.42 × 1.6, −2.1) with a sway of ±0.02 in x at 0.3 rad/s: far above the screen, so bands tilt only ≈ 10°. θ = 2.6·atan2(x − Oₓ, y − O_y); the 2.6 restores the angular scale the fan had with a nearer point.
**Charge `p`.** Target `g = smoothstep(0, 0.5, overhang)` on a critically damped spring, ω 11.1 up, 8.6 down (90 % in ~350 / ~450 ms). With P = smoothstep(0, 1, p): `head = −0.05 + 0.74√P`, `wid = 0.95 − 0.42P`, `fan = gain·smoothstep(.08, .8, p)`, `pale = pale·smoothstep(.4, 1, p)`, `reach = 1.9 − 0.8P`, `bloom = bloom·P(0.4 + 0.6P)`, `bloomR = 0.2 + bloomR·P`, `dim = dim·smoothstep(.08, .9, p)`.
**Field (HDR radiance X, added).**
- Shafts: a warped θ runs through two octaves of slow incommensurate sines (×6 and ×13), `0.45 + 1.3·(broad·(0.55 + 0.45·fine))^contrast`, evaluated once per channel with θ ∓ 0.012·disp and radius × (1 ± 0.05·disp): the chromatic dispersion.
- Colour: `a = (θ − (head − wid)) / wid + small wobble`; `0.5 + 0.5·cos(2π(0.72a − 0.09 − {0, ⅓, ⅔}))`, one hue sweep pink → red → amber → green → cyan → blue with no knots, mixed toward white by `sat`, washing to warm white over a .7…1.25 by `pale`.
- Envelopes: window `smoothstep(−.55, .25, a)·(1 − tail·smoothstep(.55, 1.5, a))`; distance `1 − smoothstep(reach − .65, reach + .45, d)`; height `0.16 + 0.84·exp(−(y − along)²/0.16)`; slow haze 0.78…1.
- Bloom: two Gaussians of `d` (radius `bloomR` and 0.4·`bloomR`), per channel with d × (1 ∓ 0.035·disp) for a prismatic rim. Optional anamorphic streak along the inward axis (`streak`, blue-tinted).
- Flash: `flash·exp(−(max(d − front, 0)/fe)²)`, `fe = 0.1 + 0.32·front`, plus a brief `veil`.
**Tone map and compositing.** `L = 1 − exp(−X)`, so highlights roll off instead of clipping. Output is premultiplied: rgb = L, alpha = wallpaper occlusion from `mix(luma, peak, .8)` and dimming, an approximation of screen blending because window alpha is one number. Triangular noise of ±1 LSB (rgb and alpha) plus light-proportional grain prevents banding. The tile sits above the light on the Mac.
**Commit (t = s since commit, T = `dissolve`), params start from max(peak charge, 0.6).** `end = 1 − smoothstep(.55T, T, t)`. `front = .04 + reach·(1 − exp(−t/.13))`, flash rises over 35 ms and decays with `flashTau`, veil decays with τ 90 ms. The fan swings away (`head −= .95·smoothstep(.03, .75, t)`, `tail = smoothstep(.04, .5, t)`, `wid → .34`), so it thins to the rainbow stripe of the reference; `fan` decays with τ .3T, `bloom` with τ .3 s, `dim` with τ .36T, each × `end`, so everything reaches exactly zero at T.
**One screen (handoff).** Two screens behave as one surface with the light source on the seam; no protocol change, the drag messages are the clock. During a drag the sender's charge follows `smoothstep(0, .25, o)·(1 − .55·smoothstep(.25, 1, o))`, so light pours across as the receiver's rises. On commit the sender runs a wave to the seam (`front` 1.7 → 0, `ring` 2.2, strength ramps to 1), its bands sweep toward the edge (`head += .5`) and its tile leaves through the seam; the receiver inhales for one beat of 90 ms (bloom tightens, dim deepens, tile recoils), then the flash answers at the seam and its bands continue in the same physical direction. The flash rises over 50 ms, holds 180 ms, then decays; the commit formulas above run on `max(t − .09, 0)`, with `tail` over .04–.35.
**Alive and reactive.** Shaft time runs at 2.6×; fan and bloom breathe ±10 % / ±8 % at 1.9 rad/s; `head` leans by `.25·(along − .5)`; drag speed (spring, ω 6) adds up to 50 % fan and 150 % warp. Crossing the commit line (overhang .5 phone drag, .83 Mac zone) fires one pulse: bloom +90 %, a `ring` of .6, a tick on the phone; commit gives a stronger haptic. A wave `ring` (per-channel, so prismatic) also shoves the shafts as it passes. The tile lives in the light: on the Mac a rim glow with charge and a white burn-out with the flash (on the phone the field already draws over the tile); it recoils, overshoots inward and settles at +.26 tile.
**Armed pulse.** The armed pulse is slower and thicker: ring 1.0, `front = .05 + .95(1 − exp(−t/.3))`, decay τ .42 s; ring width `.07 + .16·front`.
**Whole-screen state (from the product video).** Lifting a file blurs and darkens everything on the phone; on the Mac the wallpaper softens outward from the seam (`NSVisualEffectView` masked radially). The tile keeps the file's shape and is drawn above the light on both screens. On commit the wave carries it ~42 % of the way into the screen with a slight lean; the dome stays up `flashHold` (A .45, B .7, C .85 s) with a thin rainbow rim, then clears in ~.3 s. When saved, the tile shrinks into the top-right desktop-style column, whose newest item is on top. The sender shows a dashed slot with a blue ring until `saved`.
**One dome.** The flash is one physical circle centred on the seam: same radius in millimetres on both screens, Mac-sized in both directions, so it overflows the phone. It opens 220 ms after the inhale, as the tile arrives, and pre-commit bloom stays well short of half the screen.
**Measured timing (reference clips, supersedes the numbers above where they differ).** The charge rises over ~1 s (ω 3.9): colours appear at the far side and sweep to the seam, darkness closing in behind them. Both screens run the circle on the same clock, 310 ms after commit: a disc at the seam whose inside clears after ~120 ms, leaving a rainbow rim that keeps travelling (`front` τ .22 s) and fades by ~.6 s, then cold blue-white shafts by ~.8 s. The tile lands, shrinks to 20 % where it is from .55 s over 200 ms, and its desktop icon appears; it does not fly there.
**A throw never stops.** On commit the Mac tile keeps its drag speed: one critically damped move (ω 9) from where it is to 42 % of the way in, with no pause at the edge. The sender's tile leaves through the seam at once. Releasing early on the phone at more than 1.2 px/ms lets the tile fly on by itself until it passes the commit line.
**Looks** (`LightLook.all` / `Looks`): A subtle pastel, B reference (default), C dramatic. Mac: env `LIDROP_LOOK=A|B|C` or menu "Light look", which also has "Preview light". Android: tap the "Light" chip in debug builds, or `adb shell am start -n dev.lidrop/.MainActivity --es look A --ez fxdemo true` (`--ez fallback true` forces the gradients).
**Strength.** Receiving screen 1. Sending screen stays subtle: phone 0.3 (dim, fan, flash, veil; bloom 0.65), Mac (Mac → phone) 0.5.
**Costs.** Mac: a display-linked tick does a dozen scalars; rendering runs on its own queue with two frames in flight and skips rather than waits, so `nextDrawable` can never delay `drag_move`. One 3-vertex draw into a `CAMetalLayer` at 1× points scale (2× cost 2.5× the GPU time for no visible gain; `LIDROP_LIGHT_SCALE` overrides, `LIDROP_DEBUG_FX=1` prints timing after each drag). Android: API 33+ draws into a `RenderNode` compositing layer at ⅓ size and scales up, with a full-size tiled grain pass on top because the A17's full 1080×2340 at 90 Hz is too slow. API < 33, or a shader that fails to compile, falls back to fixed pastel gradients (sweep fan on side edges, dim, bloom, flash), a cruder picture.

## iPhone
Same protocol, same `hello` (`id`, `token`, `role`), so the Mac does not know which phone it is. What differs is how the same behaviour is reached:
- Discovery: `NWBrowser` on `_lidrop._tcp`. Connection rules as on Android: tunnel first, plain LAN for a network with no internet.
- Tunnel: iOS cannot start a binary, so `ios/tunnel` is `dumbpipe connect-tcp` as a library. It binds a free loopback port per process instead of 17777, because the Share extension is a second process and a suspended app keeps its port. Stopped when the app leaves the screen; iOS would kill its sockets.
- Share target: the `LidropShare` extension, its own connection with `role` `share`. An App Group shares `id`, `token` and `ticket` with the app, so the Mac sees one trusted phone. The tile is picked up on the first touch.
- Light: `ios/Lidrop/Shaders.swift`, the same formulas again; keep it in step with `Effects.swift` and `Light.kt`. Drawn at 1.5× points into a `CAMetalLayer` that skips a frame rather than ever waits.
- Received files go to the app's Documents folder, shown in Files → On My iPhone → lidrop.

## Windows
`windows/` plays the Mac's role in both directions: same port, service, framing, `hello`, `trust.json`, ceremony and `dumbpipe`, so the phone cannot tell it from a Mac and every "Mac" above reads "computer". Android only so far. What differs is how the same behaviour is reached:
- Finding a file drag: Windows keeps it private to the window under the cursor, so a nearly invisible 24 pt strip along the learned edge joins OLE drag and drop, only while the left button is held within 120 pt of that edge. `zone`, `overhang` and the 4 pt commit rule are the Mac's, in points (DPI / 96).
- `want` is never sent: a video is saved, not played, while it arrives.
- `screen_mm` comes from the monitor's raw DPI. `safe_name` makes names from the phone safe for NTFS (`\`, `:` streams, device names, trailing dots).
- The overlay is the tile, the lens and the wave, drawn on the CPU with the same numbers as `Overlay.swift` and `GlassFX`; no light field yet. Keep `windows/core/src/stage.rs` and `render.rs` in step with them.

## Out of scope for the demo
rotated/mirrored layouts, multi-display placement (demo uses the main display), discovery (mDNS), pairing/Allow, TLS, folders, resume, multi-device, real sensing of physical position (would need UWB hardware; drag direction is the signal).
