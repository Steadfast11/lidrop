//! Small questions for Windows: where things are, what a screen measures, what a file looks like.
use lidrop_core::render::{Image, Mask};
use lidrop_core::stage::ScreenInfo;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use windows::core::{w, HSTRING, PCWSTR};
use windows::Win32::Foundation::{HANDLE, HWND, POINT};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::Com::{CoInitializeEx, CoTaskMemFree, COINIT_APARTMENTTHREADED};
use windows::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::CF_UNICODETEXT;
use windows::Win32::System::Registry::*;
use windows::Win32::System::SystemInformation::{ComputerNamePhysicalDnsHostname, GetComputerNameExW};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI, MDT_RAW_DPI};
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;

pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn wide_path(p: &Path) -> Vec<u16> {
    p.as_os_str().encode_wide().chain(Some(0)).collect()
}

pub fn computer_name() -> String {
    let mut buf = [0u16; 256];
    let mut n = buf.len() as u32;
    match unsafe { GetComputerNameExW(ComputerNamePhysicalDnsHostname, Some(windows::core::PWSTR(buf.as_mut_ptr())), &mut n) } {
        Ok(()) if n > 0 => String::from_utf16_lossy(&buf[..n as usize]),
        _ => "Windows PC".to_string(),
    }
}

fn known_folder(id: &windows::core::GUID) -> Option<PathBuf> {
    unsafe {
        let p = SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None).ok()?;
        let s = p.to_string().ok();
        CoTaskMemFree(Some(p.0 as *const _));
        s.map(PathBuf::from)
    }
}

/// The user's real Downloads folder, wherever they moved it.
pub fn save_dir() -> PathBuf {
    known_folder(&FOLDERID_Downloads)
        .or_else(|| std::env::var_os("USERPROFILE").map(|h| PathBuf::from(h).join("Downloads")))
        .unwrap_or_else(|| PathBuf::from("."))
        .join("lidrop")
}

pub fn data_dir() -> PathBuf {
    known_folder(&FOLDERID_LocalAppData)
        .or_else(|| std::env::var_os("LOCALAPPDATA").map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("."))
        .join("lidrop")
}

/// A freshly downloaded copy puts itself in lidrop's own folder and restarts there, so nobody has to keep the download.
/// True when this copy has handed over and should quit. If the copy fails lidrop is already there and running, and this
/// copy just stops at the single-instance check.
pub fn move_home() -> bool {
    let home = data_dir().join("lidrop.exe");
    let Ok(exe) = std::env::current_exe() else { return false };
    if exe.to_string_lossy().eq_ignore_ascii_case(&home.to_string_lossy()) {
        return false;
    }
    if std::fs::create_dir_all(data_dir()).is_err() || std::fs::copy(&exe, &home).is_err() {
        return false;
    }
    let _ = std::fs::remove_file(format!("{}:Zone.Identifier", home.display())); // the user has already opened it once
    std::process::Command::new(&home).spawn().is_ok()
}

/// The primary screen in physical pixels, with what it measures. EDID's raw DPI when the screen reports a sane one,
/// else the size Windows assumes.
pub fn screen() -> ScreenInfo {
    unsafe {
        let m = MonitorFromPoint(POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY);
        let mut mi = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
        let _ = GetMonitorInfoW(m, &mut mi);
        let (w, h) = ((mi.rcMonitor.right - mi.rcMonitor.left) as f64, (mi.rcMonitor.bottom - mi.rcMonitor.top) as f64);
        let (mut ex, mut ey, mut rx, mut ry) = (96u32, 96u32, 0u32, 0u32);
        let _ = GetDpiForMonitor(m, MDT_EFFECTIVE_DPI, &mut ex, &mut ey);
        let _ = GetDpiForMonitor(m, MDT_RAW_DPI, &mut rx, &mut ry);
        let mm = |px: f64, dpi: u32| px / dpi as f64 * 25.4;
        let sane = (40..=800).contains(&rx) && (40..=800).contains(&ry) && (150.0..2500.0).contains(&mm(w, rx));
        let (w_mm, h_mm) = if sane { (mm(w, rx), mm(h, ry)) } else { (mm(w, ex), mm(h, ey)) };
        ScreenInfo { w: w.max(1.0), h: h.max(1.0), mm: (w_mm, h_mm), scale: ex as f64 / 96.0 }
    }
}

pub fn open_folder(dir: &Path) {
    let _ = std::fs::create_dir_all(dir);
    let p = wide_path(dir);
    unsafe {
        ShellExecuteW(None, w!("open"), PCWSTR(p.as_ptr()), None, None, SW_SHOWNORMAL);
    }
}

/// Opens the file's folder with the file selected.
pub fn reveal(file: &Path) {
    let p = wide_path(file);
    unsafe {
        let pidl = ILCreateFromPathW(PCWSTR(p.as_ptr()));
        if !pidl.is_null() {
            let _ = SHOpenFolderAndSelectItems(pidl, None, 0);
            ILFree(Some(pidl));
        }
    }
}

pub fn copy_text(owner: HWND, text: &str) {
    let w = wide(text);
    unsafe {
        if OpenClipboard(Some(owner)).is_err() {
            return;
        }
        let _ = EmptyClipboard();
        if let Ok(h) = GlobalAlloc(GMEM_MOVEABLE, w.len() * 2) {
            let dst = GlobalLock(h) as *mut u16;
            if !dst.is_null() {
                std::ptr::copy_nonoverlapping(w.as_ptr(), dst, w.len());
                let _ = GlobalUnlock(h);
                let _ = SetClipboardData(CF_UNICODETEXT.0 as u32, Some(HANDLE(h.0)));
            }
        }
        let _ = CloseClipboard();
    }
}

const RUN_KEY: PCWSTR = w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run");

pub fn launch_at_login() -> bool {
    unsafe { RegGetValueW(HKEY_CURRENT_USER, RUN_KEY, w!("lidrop"), RRF_RT_REG_SZ, None, None, None).is_ok() }
}

pub fn set_launch_at_login(on: bool) {
    unsafe {
        if on {
            let Ok(exe) = std::env::current_exe() else { return };
            let v = wide(&format!("\"{}\"", exe.display()));
            let _ = RegSetKeyValueW(HKEY_CURRENT_USER, RUN_KEY, w!("lidrop"), REG_SZ.0, Some(v.as_ptr() as *const _), (v.len() * 2) as u32);
        } else {
            let _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, RUN_KEY, w!("lidrop"));
        }
    }
}

/// The taskbar's colours: does a glyph on it need to be dark?
pub fn taskbar_is_light() -> bool {
    let mut v = 0u32;
    let mut n = 4u32;
    unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
            w!("SystemUsesLightTheme"),
            RRF_RT_REG_DWORD,
            None,
            Some(&mut v as *mut u32 as *mut _),
            Some(&mut n),
        )
        .is_ok()
            && v != 0
    }
}

fn bitmap_pixels(bmp: HBITMAP) -> Option<(u32, u32, Vec<u8>)> {
    unsafe {
        let mut b = BITMAP::default();
        if GetObjectW(bmp.into(), size_of::<BITMAP>() as i32, Some(&mut b as *mut _ as *mut _)) == 0 {
            return None;
        }
        let (w, h) = (b.bmWidth, b.bmHeight.abs());
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
        let mut px = vec![0u8; (w * h * 4) as usize];
        let dc = CreateCompatibleDC(None);
        let got = GetDIBits(dc, bmp, 0, h as u32, Some(px.as_mut_ptr() as *mut _), &mut info, DIB_RGB_COLORS);
        let _ = DeleteDC(dc);
        (got != 0).then_some((w as u32, h as u32, px))
    }
}

/// What Explorer would show for this file, at up to 512 px: its thumbnail, or with `icon_only` its icon, which is
/// always quick.
pub fn file_image(path: &Path, icon_only: bool) -> Option<Image> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let item: IShellItemImageFactory = SHCreateItemFromParsingName(&HSTRING::from(path.as_os_str()), None).ok()?;
        let flags = if icon_only { SIIGBF_ICONONLY } else { SIIGBF_BIGGERSIZEOK };
        let bmp = item.GetImage(windows::Win32::Foundation::SIZE { cx: 512, cy: 512 }, flags).ok()?;
        let px = bitmap_pixels(bmp);
        let _ = DeleteObject(bmp.into());
        let (w, h, mut px) = px?;
        let opaque = px.chunks_exact(4).all(|p| p[3] == 0); // thumbnails come with no alpha at all
        for p in px.chunks_exact_mut(4) {
            p.swap(0, 2);
            if opaque {
                p[3] = 255;
            } else if p[3] != 0 && p[3] != 255 {
                let a = p[3] as u32;
                for c in &mut p[..3] {
                    *c = (*c as u32 * 255 / a).min(255) as u8; // the shell's icons are premultiplied
                }
            }
        }
        Some(Image { w, h, rgba: px })
    }
}

/// White-on-nothing text from Windows' own font, for the count on a stack of tiles.
pub fn text_mask(text: &str, px_height: i32) -> Option<Mask> {
    let (w, h) = (px_height * text.len().max(1) as i32 + 4, px_height * 3 / 2);
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
        let font = CreateFontW(-px_height, 0, 0, 0, 600, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, 0, w!("Segoe UI"));
        let old_font = SelectObject(dc, font.into());
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, windows::Win32::Foundation::COLORREF(0x00ff_ffff));
        let mut wtext: Vec<u16> = text.encode_utf16().collect();
        let mut rc = windows::Win32::Foundation::RECT { left: 0, top: 0, right: w, bottom: h };
        DrawTextW(dc, &mut wtext, &mut rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        let _ = GdiFlush();
        let src = std::slice::from_raw_parts(bits as *const u32, (w * h) as usize);
        let a: Vec<u8> = src.iter().map(|p| (p >> 16 & 255) as u8).collect();
        SelectObject(dc, old_font);
        SelectObject(dc, old);
        let _ = DeleteObject(font.into());
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(dc);
        Some(Mask { w: w as usize, h: h as usize, a })
    }
}
