//! The app itself: no window, one icon by the clock, and the threads behind it.
use crate::{ask, dropzone, overlay, shell};
use lidrop_core::render::tray_glyph;
use lidrop_core::server::{Config, Cue, Host, Note, Server};
use lidrop_core::discovery::{self, Advert};
use lidrop_core::tunnel::Tunnel;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, OnceLock};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::Com::{CoInitializeEx, COINIT_APARTMENTTHREADED};
use windows::Win32::System::JobObjects::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Ole::OleInitialize;
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use std::os::windows::io::AsRawHandle;

const WM_TRAY: u32 = WM_APP + 1;
const WM_CHANGED: u32 = WM_APP + 2;
const WM_NOTE: u32 = WM_APP + 3;
pub const WM_STRIP: u32 = WM_APP + 4;

const NIN_KEY_SELECT: u32 = NIN_SELECT | NINF_KEY;

const ID_COPY: usize = 1;
const ID_OPEN: usize = 2;
const ID_LOGIN: usize = 3;
const ID_QUIT: usize = 4;

const PORT: u16 = 7777;
const DUMBPIPE_FILE: &str = "dumbpipe-0.40.1.exe";

#[derive(Default)]
struct Ui {
    phones: Vec<String>,
    progress: Option<u32>,
    notes: Vec<Note>,
    reveal: Option<PathBuf>,
}

struct App {
    cues: overlay::Cues,
    ui: Mutex<Ui>,
    hwnd: isize,
    name: String,
}

impl App {
    fn post(&self, msg: u32) {
        unsafe {
            let _ = PostMessageW(Some(HWND(self.hwnd as *mut _)), msg, WPARAM(0), LPARAM(0));
        }
    }
}

impl Host for App {
    fn device_name(&self) -> String {
        self.name.clone()
    }
    fn screen_mm(&self) -> Option<(f64, f64)> {
        Some(shell::screen().mm)
    }
    fn ask_allow(&self, phone: &str, gone: &AtomicBool) -> bool {
        ask::allow(phone, gone)
    }
    fn cue(&self, c: Cue) {
        self.cues.send(c);
    }
    fn phones(&self, names: Vec<String>) {
        self.ui.lock().unwrap().phones = names;
        self.post(WM_CHANGED);
    }
    fn note(&self, n: Note) {
        self.ui.lock().unwrap().notes.push(n);
        self.post(WM_NOTE);
    }
}

struct Running {
    app: Arc<App>,
    srv: Arc<Server>,
    strip: isize,
    ip: String,
    tunnel: Option<Tunnel>,
    _mdns: Option<Advert>,
}

static RUNNING: OnceLock<Mutex<Option<Running>>> = OnceLock::new();

fn with<R>(f: impl FnOnce(&Running) -> R) -> Option<R> {
    RUNNING.get()?.lock().ok()?.as_ref().map(f)
}

fn tip_units(s: &str, out: &mut [u16]) {
    for (i, u) in s.encode_utf16().take(out.len() - 1).enumerate() {
        out[i] = u;
        out[i + 1] = 0;
    }
}

fn icon_for(connected: bool) -> HICON {
    unsafe {
        let size = GetSystemMetrics(SM_CXSMICON).max(16) as usize;
        let rgb = if shell::taskbar_is_light() { [28, 28, 30] } else { [245, 245, 247] };
        let px = tray_glyph(size, connected, rgb);
        let mut info = BITMAPINFO::default();
        info.bmiHeader = BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: size as i32,
            biHeight: -(size as i32),
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        let Ok(color) = CreateDIBSection(None, &info, DIB_RGB_COLORS, &mut bits, None, 0) else { return HICON::default() };
        std::ptr::copy_nonoverlapping(px.as_ptr(), bits as *mut u8, px.len());
        let mask = CreateBitmap(size as i32, size as i32, 1, 1, None);
        let ii = ICONINFO { fIcon: true.into(), hbmMask: mask, hbmColor: color, ..Default::default() };
        let icon = CreateIconIndirect(&ii).unwrap_or_default();
        let _ = DeleteObject(color.into());
        let _ = DeleteObject(mask.into());
        icon
    }
}

fn base_data(hwnd: HWND) -> NOTIFYICONDATAW {
    NOTIFYICONDATAW { cbSize: size_of::<NOTIFYICONDATAW>() as u32, hWnd: hwnd, uID: 1, ..Default::default() }
}

fn add_icon(hwnd: HWND) {
    let mut d = base_data(hwnd);
    d.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    d.uCallbackMessage = WM_TRAY;
    d.hIcon = icon_for(false);
    tip_units("lidrop", &mut d.szTip);
    unsafe {
        let _ = Shell_NotifyIconW(NIM_ADD, &d);
        let _ = DestroyIcon(d.hIcon);
        d.Anonymous.uVersion = NOTIFYICON_VERSION_4;
        let _ = Shell_NotifyIconW(NIM_SETVERSION, &d);
    }
    refresh(hwnd);
}

/// Icon and tooltip say what the menu says.
fn refresh(hwnd: HWND) {
    let (phones, progress) = with(|r| {
        let ui = r.app.ui.lock().unwrap();
        (ui.phones.clone(), ui.progress)
    })
    .unwrap_or_default();
    let mut d = base_data(hwnd);
    d.uFlags = NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    d.hIcon = icon_for(!phones.is_empty());
    let tip = match (progress, phones.first()) {
        (Some(p), _) => format!("lidrop: receiving {p}%"),
        (None, Some(n)) => format!("lidrop: {n}"),
        (None, None) => "lidrop".to_string(),
    };
    tip_units(&tip, &mut d.szTip);
    unsafe {
        let _ = Shell_NotifyIconW(NIM_MODIFY, &d);
        let _ = DestroyIcon(d.hIcon);
    }
}

/// Quiet by design: no sound, and Windows holds it back during a presentation or full-screen app.
fn toast(hwnd: HWND, title: &str, text: &str) {
    let mut d = base_data(hwnd);
    d.uFlags = NIF_INFO;
    d.dwInfoFlags = NIIF_NONE | NIIF_NOSOUND | NIIF_RESPECT_QUIET_TIME;
    tip_units(title, &mut d.szInfoTitle);
    tip_units(text, &mut d.szInfo);
    unsafe {
        let _ = Shell_NotifyIconW(NIM_MODIFY, &d);
    }
}

fn handle_notes(hwnd: HWND) {
    let notes = with(|r| std::mem::take(&mut r.app.ui.lock().unwrap().notes)).unwrap_or_default();
    for n in notes {
        match n {
            Note::Saved(paths) => {
                let name = paths.first().and_then(|p| p.file_name()).map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                let text = if paths.len() > 1 { format!("{} files in Downloads\\lidrop", paths.len()) } else { name };
                with(|r| r.app.ui.lock().unwrap().reveal = paths.last().cloned());
                toast(hwnd, "Saved", &text);
            }
            Note::Progress(p) => {
                with(|r| r.app.ui.lock().unwrap().progress = p);
                refresh(hwnd);
            }
            Note::Sent { .. } => {} // the phone says "Received" itself
            Note::SendFailed { msg } => toast(hwnd, "Could not send", &msg),
        }
    }
}

fn show_menu(hwnd: HWND) {
    let Some((phones, ip, ticket)) = with(|r| (r.app.ui.lock().unwrap().phones.clone(), r.ip.clone(), r.srv.ticket())) else { return };
    let text = |s: &str| shell::wide(s);
    unsafe {
        let Ok(m) = CreatePopupMenu() else { return };
        let line = |flags: MENU_ITEM_FLAGS, id: usize, s: &str| {
            let w = text(s);
            let _ = AppendMenuW(m, flags, id, PCWSTR(w.as_ptr()));
        };
        line(MF_GRAYED, 0, &if phones.is_empty() { "Disconnected".to_string() } else { format!("Connected phones: {}", phones.len()) });
        phones.iter().for_each(|n| line(MF_GRAYED, 0, &format!("    {n}")));
        line(MF_GRAYED, 0, &format!("{ip}:{PORT}"));
        line(if ticket.is_some() { MF_ENABLED } else { MF_GRAYED }, ID_COPY, "Copy pairing code");
        let _ = AppendMenuW(m, MF_SEPARATOR, 0, None);
        line(MF_ENABLED, ID_OPEN, "Open Downloads\\lidrop");
        line(if shell::launch_at_login() { MF_CHECKED } else { MF_UNCHECKED }, ID_LOGIN, "Launch at login");
        line(MF_ENABLED, ID_QUIT, "Quit");
        let mut p = POINT::default();
        let _ = GetCursorPos(&mut p);
        let _ = SetForegroundWindow(hwnd); // or the menu would not close on a click elsewhere
        let picked = TrackPopupMenu(m, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, p.x, p.y, None, hwnd, None);
        let _ = PostMessageW(Some(hwnd), WM_NULL, WPARAM(0), LPARAM(0));
        let _ = DestroyMenu(m);
        match picked.0 as usize {
            ID_COPY => {
                if let Some(t) = with(|r| r.srv.ticket()).flatten() {
                    shell::copy_text(hwnd, &t);
                }
            }
            ID_OPEN => {
                if let Some(d) = with(|r| r.srv.save_dir().to_path_buf()) {
                    shell::open_folder(&d);
                }
            }
            ID_LOGIN => shell::set_launch_at_login(!shell::launch_at_login()),
            ID_QUIT => PostQuitMessage(0),
            _ => {}
        }
    }
}

static TASKBAR_CREATED: OnceLock<u32> = OnceLock::new();

unsafe extern "system" fn proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_TRAY => match (lp.0 & 0xffff) as u32 {
            NIN_SELECT | NIN_KEY_SELECT | WM_CONTEXTMENU => show_menu(hwnd),
            NIN_BALLOONUSERCLICK => {
                if let Some(Some(p)) = with(|r| r.app.ui.lock().unwrap().reveal.clone()) {
                    shell::reveal(&p);
                }
            }
            _ => {}
        },
        WM_CHANGED => refresh(hwnd),
        WM_NOTE => handle_notes(hwnd),
        WM_STRIP => {
            let (v, strip) = (lp.0, with(|r| r.strip).unwrap_or(0));
            let r = RECT { left: (v >> 48) as i16 as i32, top: (v >> 32) as i16 as i32, right: (v >> 16) as i16 as i32, bottom: v as i16 as i32 };
            dropzone::show_strip(HWND(strip as *mut _), wp.0 != 0, r);
        }
        WM_SETTINGCHANGE => refresh(hwnd), // the taskbar may have changed between light and dark
        WM_DESTROY => PostQuitMessage(0),
        _ if Some(&msg) == TASKBAR_CREATED.get() => add_icon(hwnd), // Explorer restarted and forgot its icons
        _ => return DefWindowProcW(hwnd, msg, wp, lp),
    }
    LRESULT(0)
}

/// Dies with this process, however this process dies: two tunnels on one key steal each other's connections.
fn kill_on_exit_job() -> HANDLE {
    unsafe {
        let Ok(job) = CreateJobObjectW(None, None) else { return HANDLE::default() };
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let _ = SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits as *const _ as *const _, size_of_val(&limits) as u32);
        job
    }
}

/// The tunnel binary: inside this .exe when it was built with one, else next to it.
fn dumbpipe(data: &std::path::Path) -> Option<PathBuf> {
    #[cfg(embedded_dumbpipe)]
    {
        static BYTES: &[u8] = include_bytes!(env!("LIDROP_DUMBPIPE"));
        let p = data.join(DUMBPIPE_FILE);
        let same = std::fs::metadata(&p).is_ok_and(|m| m.len() == BYTES.len() as u64);
        if same || std::fs::write(&p, BYTES).is_ok() {
            return Some(p);
        }
    }
    let _ = (data, DUMBPIPE_FILE);
    let beside = std::env::current_exe().ok()?.with_file_name("dumbpipe.exe");
    beside.exists().then_some(beside)
}

fn message(text: &str) {
    let t = shell::wide(text);
    unsafe {
        MessageBoxW(None, PCWSTR(t.as_ptr()), w!("lidrop"), MB_OK | MB_ICONWARNING | MB_TOPMOST);
    }
}

/// Starts with Windows from now on, and says once where it went: a tray app shows no window of its own.
fn first_launch(data: &std::path::Path) {
    let mark = data.join("settled");
    if mark.exists() {
        return;
    }
    let _ = std::fs::write(&mark, "");
    shell::set_launch_at_login(true);
    std::thread::spawn(|| unsafe {
        MessageBoxW(None, w!("lidrop is ready. It stays by the clock and starts with Windows. Now open lidrop on your phone."), w!("lidrop"), MB_OK | MB_ICONINFORMATION | MB_TOPMOST);
    });
}

pub fn run() {
    if shell::move_home() {
        return;
    }
    unsafe {
        let _ = windows::Win32::UI::HiDpi::SetProcessDpiAwarenessContext(windows::Win32::UI::HiDpi::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let one = CreateMutexW(None, false, w!("Local\\lidrop-single-instance"));
        if GetLastError() == ERROR_ALREADY_EXISTS {
            return; // it is already by the clock
        }
        let _ = one;
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let _ = OleInitialize(None);
        TASKBAR_CREATED.set(RegisterWindowMessageW(w!("TaskbarCreated"))).ok();

        let inst: HINSTANCE = GetModuleHandleW(None).unwrap_or_default().into();
        let class = WNDCLASSW { lpfnWndProc: Some(proc), hInstance: inst, lpszClassName: w!("lidrop.tray"), ..Default::default() };
        RegisterClassW(&class);
        let hwnd = CreateWindowExW(WINDOW_EX_STYLE(0), w!("lidrop.tray"), w!("lidrop"), WS_OVERLAPPED, 0, 0, 0, 0, None, None, Some(inst), None).expect("the tray window");

        let data = shell::data_dir();
        let _ = std::fs::create_dir_all(&data);
        let name = shell::computer_name();
        let app = Arc::new(App { cues: overlay::start(), ui: Mutex::default(), hwnd: hwnd.0 as isize, name: name.clone() });
        let cfg = Config { data_dir: data.clone(), save_dir: shell::save_dir(), port: PORT };
        let srv = match Server::new(app.clone(), cfg) {
            Ok(s) => s,
            Err(e) => return message(&format!("lidrop could not open its folder: {e}")),
        };
        if let Err(e) = srv.start() {
            return message(&format!("lidrop could not listen on port {PORT}: {e}"));
        }
        let mdns = discovery::advertise(&name, PORT).ok();
        let strip = dropzone::start(srv.clone(), hwnd);
        let job = kill_on_exit_job().0 as isize;
        let tunnel = dumbpipe(&data).map(|bin| {
            let s = srv.clone();
            Tunnel::start(
                bin,
                PORT,
                &data.join("tunnel.key"),
                move |t| s.set_ticket(t),
                move |child| {
                    let _ = AssignProcessToJobObject(HANDLE(job as *mut _), HANDLE(child.as_raw_handle()));
                },
            )
        });
        let ip = discovery::local_ip().map_or_else(|| "0.0.0.0".to_string(), |i| i.to_string());
        RUNNING.set(Mutex::new(Some(Running { app, srv, strip: strip.0 as isize, ip, tunnel, _mdns: mdns }))).ok();
        add_icon(hwnd);
        first_launch(&data);

        let mut m = MSG::default();
        while GetMessageW(&mut m, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&m);
            DispatchMessageW(&m);
        }
        let _ = Shell_NotifyIconW(NIM_DELETE, &base_data(hwnd));
        if let Some(r) = RUNNING.get().and_then(|r| r.lock().ok()?.take()) {
            if let Some(t) = &r.tunnel {
                t.stop();
            }
        }
    }
}
