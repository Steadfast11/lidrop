//! lidrop for Windows: a tray app with no window. The protocol lives in `lidrop-core`; this is the Win32 around it.
#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
mod ask;
#[cfg(windows)]
mod dropzone;
#[cfg(windows)]
mod overlay;
#[cfg(windows)]
mod shell;
#[cfg(windows)]
mod tray;

#[cfg(windows)]
fn main() {
    tray::run();
}

#[cfg(not(windows))]
fn main() {
    eprintln!("lidrop.exe is a Windows app. Here, run the core with: cargo run -p lidrop-core --example headless");
}
