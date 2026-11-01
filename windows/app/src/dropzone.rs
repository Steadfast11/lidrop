//! Windows → phone. Windows keeps a file drag private to whoever it is over, so the way to learn about one is to be
//! under it: while the left button is held near the edge that leads to the phone, a nearly invisible strip sits along
//! that edge and takes part in OLE drag and drop. A plain click can never land on it: it only exists mid-press.
use crate::overlay::default_proc;
use crate::{shell, tray};
use lidrop_core::server::{Edge, Server};
use lidrop_core::stage::ScreenInfo;
use lidrop_core::thumb;
use lidrop_core::zone::{self, Handoff};
use std::path::PathBuf;
use std::sync::mpsc::channel;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};
use windows::core::{implement, w, Ref};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Dwm::DwmFlush;
use windows::Win32::System::Com::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Ole::*;
use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;

const THUMB_WAIT: Duration = Duration::from_millis(200);

fn dropped_files(data: &IDataObject) -> Vec<PathBuf> {
    let fmt = FORMATETC { cfFormat: CF_HDROP.0, ptd: std::ptr::null_mut(), dwAspect: DVASPECT_CONTENT.0, lindex: -1, tymed: TYMED_HGLOBAL.0 as u32 };
    let mut out = Vec::new();
    unsafe {
        let Ok(mut medium) = data.GetData(&fmt) else { return out };
        let drop = HDROP(medium.u.hGlobal.0);
        for i in 0..DragQueryFileW(drop, u32::MAX, None) {
            let mut buf = vec![0u16; DragQueryFileW(drop, i, None) as usize + 1];
            let n = DragQueryFileW(drop, i, Some(&mut buf)) as usize;
            out.push(PathBuf::from(String::from_utf16_lossy(&buf[..n])));
        }
        ReleaseStgMedium(&mut medium);
    }
    out
}

fn thumbnail(first: PathBuf) -> String {
    let (tx, rx) = channel();
    let p = first.clone();
    thread::spawn(move || {
        let _ = tx.send(shell::file_image(&p, false));
    });
    // never hold the drag back for a slow file: past the wait, its icon will do
    let img = rx.recv_timeout(THUMB_WAIT).ok().flatten().or_else(|| shell::file_image(&first, true));
    img.and_then(|i| thumb::square_jpeg(&i)).unwrap_or_default()
}

#[implement(IDropTarget)]
struct Target {
    out: Arc<Handoff>,
}

impl IDropTarget_Impl for Target_Impl {
    fn DragEnter(&self, data: Ref<'_, IDataObject>, _: MODIFIERKEYS_FLAGS, _: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        let files = data.as_ref().map(dropped_files).unwrap_or_default();
        unsafe {
            // copy, always: a move would delete the user's file once the phone has it
            let can = *effect & DROPEFFECT_COPY == DROPEFFECT_COPY && !files.is_empty();
            *effect = if can { DROPEFFECT_COPY } else { DROPEFFECT_NONE };
            if can {
                self.out.begin(files, |f| thumbnail(f[0].clone()));
            }
        }
        Ok(())
    }

    fn DragOver(&self, _: MODIFIERKEYS_FLAGS, _: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        unsafe {
            *effect = if self.out.accepting() && *effect & DROPEFFECT_COPY == DROPEFFECT_COPY { DROPEFFECT_COPY } else { DROPEFFECT_NONE };
        }
        Ok(())
    }

    fn DragLeave(&self) -> windows::core::Result<()> {
        Ok(()) // the drag goes on until the button comes up; the watcher sends overhang 0 meanwhile
    }

    fn Drop(&self, _: Ref<'_, IDataObject>, _: MODIFIERKEYS_FLAGS, pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        let s = shell::screen();
        let (dist, _) = zone::geometry(pt.x as f64, pt.y as f64, self.out.server().edge(), &s);
        let commit = zone::commits(dist, &s);
        self.out.finish(commit);
        unsafe {
            *effect = if commit { DROPEFFECT_COPY } else { DROPEFFECT_NONE };
        }
        Ok(())
    }
}

/// The physical left button, even for left-handed mouse settings.
fn button_down() -> bool {
    let vk = if unsafe { GetSystemMetrics(SM_SWAPBUTTON) } != 0 { VK_RBUTTON } else { VK_LBUTTON };
    unsafe { GetAsyncKeyState(vk.0 as i32) as u16 & 0x8000 != 0 }
}

/// A game or a video filling the screen is not a place for an extra window.
fn fullscreen_app() -> bool {
    matches!(unsafe { SHQueryUserNotificationState() }, Ok(QUNS_RUNNING_D3D_FULL_SCREEN) | Ok(QUNS_BUSY) | Ok(QUNS_PRESENTATION_MODE))
}

/// Watches the button and the cursor on its own thread and steers the strip, which belongs to the tray thread.
fn watch(out: Arc<Handoff>, tray: isize) {
    let srv = out.server().clone();
    let (mut was_down, mut armed, mut allowed) = (false, false, false);
    let mut press = POINT::default();
    let mut up_at: Option<Instant> = None;
    let mut s = shell::screen();
    let mut last = (-1.0, -1.0);
    let strip = |show: bool, edge: Edge, s: &ScreenInfo| unsafe {
        let (l, t, r, b) = zone::strip(edge, s);
        let packed = (l as isize) << 48 | (t as isize & 0xffff) << 32 | (r as isize & 0xffff) << 16 | (b as isize & 0xffff);
        let _ = PostMessageW(Some(HWND(tray as *mut _)), tray::WM_STRIP, WPARAM(show as usize), LPARAM(packed));
    };
    loop {
        let down = button_down();
        let mut p = POINT::default();
        unsafe {
            let _ = GetCursorPos(&mut p);
        }
        let edge = srv.edge();
        if down && !was_down {
            s = shell::screen();
            press = p;
            allowed = zone::press_counts(zone::geometry(p.x as f64, p.y as f64, edge, &s).0, &s);
            up_at = None;
        }
        let (dist, along) = zone::geometry(p.x as f64, p.y as f64, edge, &s);
        if down && !armed && allowed {
            let moved = (p.x - press.x).abs() + (p.y - press.y).abs() > 6;
            if moved && zone::near_enough(dist, &s) && srv.can_send() && !fullscreen_app() {
                armed = true;
                strip(true, edge, &s);
            }
        }
        if armed {
            let now = (along.clamp(0.0, 1.0), zone::overhang(dist, &s));
            if now != last {
                last = now;
                out.moved(now.0, now.1);
            }
            if !down {
                // the drop lands on the tray thread; give it a moment, else this was a release somewhere else
                let t = *up_at.get_or_insert_with(Instant::now);
                if t.elapsed() > Duration::from_millis(250) {
                    out.finish(false);
                    strip(false, edge, &s);
                    armed = false;
                    up_at = None;
                    last = (-1.0, -1.0);
                }
            }
        }
        was_down = down;
        if armed {
            if unsafe { DwmFlush() }.is_err() {
                thread::sleep(Duration::from_millis(8)); // one drag_move per display frame, like the Mac's
            }
        } else {
            thread::sleep(Duration::from_millis(if srv.can_send() { 16 } else { 200 }));
        }
    }
}

/// Runs on the tray thread: the strip, and `IDropTarget`, must live on a thread with a message loop.
pub fn show_strip(hwnd: HWND, show: bool, r: RECT) {
    unsafe {
        if show {
            let _ = SetWindowPos(hwnd, Some(HWND_TOPMOST), r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        } else {
            let _ = ShowWindow(hwnd, SW_HIDE);
        }
    }
}

pub fn start(srv: Arc<Server>, tray: HWND) -> HWND {
    unsafe {
        let inst: HINSTANCE = GetModuleHandleW(None).unwrap_or_default().into();
        let class = WNDCLASSW { lpfnWndProc: Some(default_proc), hInstance: inst, lpszClassName: w!("lidrop.strip"), ..Default::default() };
        RegisterClassW(&class);
        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            w!("lidrop.strip"),
            w!("lidrop strip"),
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
        .expect("the strip window");
        // 1 of 255: invisible, but a window, so OLE finds it under the cursor
        let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 1, LWA_ALPHA);
        let out = Handoff::new(srv);
        let target: IDropTarget = Target { out: out.clone() }.into();
        let _ = RegisterDragDrop(hwnd, &target);
        let tray = tray.0 as isize;
        thread::spawn(move || watch(out, tray));
        hwnd
    }
}
