//! The click-through window over everything. One thread owns it: cues in, `Stage` decides, `render` draws into a
//! bitmap, `UpdateLayeredWindow` shows it, paced by the compositor. Nothing here can hold up a `drag_move`.
use crate::shell;
use lidrop_core::render::{self, build_sprite, Canvas, Image, Rect, Sprite};
use lidrop_core::server::Cue;
use lidrop_core::stage::{ScreenInfo, Stage};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::thread;
use std::time::Instant;
use windows::core::w;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Dwm::DwmFlush;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::{CreateEventW, SetEvent, INFINITE};
use windows::Win32::UI::WindowsAndMessaging::*;

/// Sends cues to the overlay thread from anywhere.
pub struct Cues {
    tx: Sender<Cue>,
    wake: isize,
}

impl Cues {
    pub fn send(&self, c: Cue) {
        let _ = self.tx.send(c);
        unsafe {
            let _ = SetEvent(HANDLE(self.wake as *mut _));
        }
    }
}

pub fn start() -> Cues {
    let (tx, rx) = channel();
    let wake = unsafe { CreateEventW(None, false, false, None) }.expect("an event");
    let raw = wake.0 as isize;
    thread::spawn(move || run(rx, raw));
    Cues { tx, wake: raw }
}

/// The bitmap the window shows: `w`×`h` premultiplied BGRA.
struct Surface {
    dc: HDC,
    bmp: HBITMAP,
    old: HGDIOBJ,
    bits: *mut u32,
    w: i32,
    h: i32,
}

impl Surface {
    fn new(w: i32, h: i32) -> Option<Surface> {
        unsafe {
            let dc = CreateCompatibleDC(None);
            let mut info = BITMAPINFO::default();
            info.bmiHeader = BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -h,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            };
            let mut bits = std::ptr::null_mut();
            let bmp = CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0).ok()?;
            let old = SelectObject(dc, bmp.into());
            Some(Surface { dc, bmp, old, bits: bits as *mut u32, w, h })
        }
    }

    fn canvas(&mut self) -> Canvas<'_> {
        let n = self.w as usize * self.h as usize;
        Canvas { w: self.w as usize, h: self.h as usize, px: unsafe { std::slice::from_raw_parts_mut(self.bits, n) } }
    }
}

impl Drop for Surface {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.dc, self.old);
            let _ = DeleteObject(self.bmp.into());
            let _ = DeleteDC(self.dc);
        }
    }
}

pub unsafe extern "system" fn default_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    DefWindowProcW(hwnd, msg, wp, lp)
}

fn create_window() -> HWND {
    unsafe {
        let inst: HINSTANCE = GetModuleHandleW(None).unwrap_or_default().into();
        let class = WNDCLASSW { lpfnWndProc: Some(default_proc), hInstance: inst, lpszClassName: w!("lidrop.overlay"), ..Default::default() };
        RegisterClassW(&class);
        CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            w!("lidrop.overlay"),
            w!("lidrop overlay"),
            WS_POPUP,
            0,
            0,
            1,
            1,
            None,
            None,
            Some(inst),
            None,
        )
        .expect("the overlay window")
    }
}

struct Window {
    hwnd: HWND,
    surface: Option<Surface>,
    shown: bool,
    prev: Rect,
    use_dirty: bool,
}

impl Window {
    fn present(&mut self, dirty: Option<Rect>) -> bool {
        let Some(s) = &self.surface else { return false };
        let size = SIZE { cx: s.w, cy: s.h };
        let (dst, src) = (POINT { x: 0, y: 0 }, POINT { x: 0, y: 0 });
        let blend = BLENDFUNCTION { BlendOp: AC_SRC_OVER as u8, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: AC_SRC_ALPHA as u8 };
        let rc = dirty.map(|r| RECT { left: r.x0, top: r.y0, right: r.x1, bottom: r.y1 });
        let info = UPDATELAYEREDWINDOWINFO {
            cbSize: size_of::<UPDATELAYEREDWINDOWINFO>() as u32,
            pptDst: &dst,
            psize: &size,
            hdcSrc: s.dc,
            pptSrc: &src,
            pblend: &blend,
            dwFlags: ULW_ALPHA,
            prcDirty: rc.as_ref().map_or(std::ptr::null(), |r| r),
            ..Default::default()
        };
        unsafe { UpdateLayeredWindowIndirect(self.hwnd, &info).as_bool() }
    }

    fn show(&mut self, s: &ScreenInfo) {
        if self.shown {
            return;
        }
        let (w, h) = (s.w as i32, s.h as i32);
        self.surface = Surface::new(w, h);
        self.prev = Rect::default();
        self.present(None); // the first update of a layered window is always the whole of it
        unsafe {
            let _ = SetWindowPos(self.hwnd, Some(HWND_TOPMOST), 0, 0, w, h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        }
        self.shown = true;
    }

    fn hide(&mut self) {
        if !self.shown {
            return;
        }
        unsafe {
            let _ = ShowWindow(self.hwnd, SW_HIDE);
        }
        self.surface = None; // a screen's worth of memory is not worth holding between drags
        self.shown = false;
    }
}

/// The picture of the current drag, turned into a sprite for its size and side.
#[derive(Default)]
struct Tile {
    image: Option<Image>,
    count: usize,
    sprite: Option<Sprite>,
    right: bool,
}

impl Tile {
    fn build(&mut self, st: &Stage, scale: f64, right: bool) {
        let badge = (26.0 * scale).max(st.tile_px() * 0.3);
        let mask = (self.count > 1).then(|| shell::text_mask(&self.count.to_string(), (badge * 0.55) as i32)).flatten();
        self.right = right;
        self.sprite = Some(build_sprite(self.image.as_ref(), st.tile_px(), scale, self.count, right, mask.as_ref()));
    }
}

fn run(rx: Receiver<Cue>, wake: isize) {
    let mut win = Window { hwnd: create_window(), surface: None, shown: false, prev: Rect::default(), use_dirty: true };
    let mut stage = Stage::default();
    let mut tile = Tile::default();
    let mut screen = shell::screen();
    let mut last = Instant::now();
    let wake = HANDLE(wake as *mut _);
    loop {
        let frame = Instant::now();
        unsafe {
            // nothing to draw: sleep until a cue, still answering Windows, which expects every window to
            let wait = if stage.visible() { 0 } else { INFINITE };
            MsgWaitForMultipleObjects(Some(&[wake]), false, wait, QS_ALLINPUT);
            let mut m = MSG::default();
            while PeekMessageW(&mut m, None, 0, 0, PM_REMOVE).as_bool() {
                DispatchMessageW(&m);
            }
        }
        while let Ok(mut c) = rx.try_recv() {
            if !stage.visible() {
                screen = shell::screen();
                last = Instant::now();
            }
            let started = if let Cue::DragStart { image, count, .. } = &mut c {
                tile.image = image.take();
                tile.count = *count;
                true
            } else {
                false
            };
            stage.cue(&c, &screen);
            if started {
                tile.build(&stage, screen.scale, render::badge_right(stage.edge()));
            }
        }
        if !stage.visible() {
            win.hide();
            continue;
        }
        win.show(&screen);
        let now = Instant::now();
        let dt = (now - last).as_secs_f64();
        last = now;
        let scene = stage.tick(dt, &screen);
        if !stage.visible() {
            win.hide();
            continue;
        }
        if let Some(p) = &scene.tile {
            let right = render::badge_right(p.edge);
            if tile.count > 1 && right != tile.right {
                tile.build(&stage, screen.scale, right);
            }
        }
        let prev = win.prev;
        let Some(s) = win.surface.as_mut() else { continue };
        let mut c = s.canvas();
        c.clear(prev);
        let mut now_drawn = Rect::default();
        if let (Some(p), Some(sprite)) = (&scene.tile, &tile.sprite) {
            now_drawn = now_drawn.union(c.sprite(sprite, p));
        }
        if let Some(g) = &scene.glass {
            now_drawn = now_drawn.union(c.glass(g));
        }
        if let Some(g) = &scene.glow {
            now_drawn = now_drawn.union(c.glow(g));
        }
        let dirty = prev.union(now_drawn);
        win.prev = now_drawn;
        unsafe {
            if !dirty.empty() {
                let _ = GdiFlush();
                if !win.present(win.use_dirty.then_some(dirty)) && win.use_dirty {
                    win.use_dirty = false; // a driver that refuses partial updates still gets the whole screen
                    win.present(None);
                }
            }
            // with no compositor to wait for (a locked screen, some remote sessions) this returns at once
            if DwmFlush().is_err() || frame.elapsed().as_millis() < 2 {
                thread::sleep(std::time::Duration::from_millis(8));
            }
        }
    }
}
