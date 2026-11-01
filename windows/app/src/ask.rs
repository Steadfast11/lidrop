//! "Allow this phone?" A real question with real answers, not Yes and No, that goes away if the phone does.
use crate::shell::wide;
use std::sync::atomic::{AtomicBool, Ordering};
use windows::core::{HRESULT, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, S_OK, WPARAM};
use windows::Win32::UI::Controls::*;
use windows::Win32::UI::WindowsAndMessaging::*;

const ALLOW: i32 = 100;
const DENY: i32 = 101;

unsafe extern "system" fn callback(hwnd: HWND, msg: TASKDIALOG_NOTIFICATIONS, _: WPARAM, _: LPARAM, data: isize) -> HRESULT {
    match msg {
        TDN_CREATED => {
            let _ = SetWindowPos(hwnd, Some(HWND_TOPMOST), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
            let _ = SetForegroundWindow(hwnd);
        }
        TDN_TIMER => {
            if (*(data as *const AtomicBool)).load(Ordering::Acquire) {
                SendMessageW(hwnd, TDM_CLICK_BUTTON.0 as u32, Some(WPARAM(DENY as usize)), None);
            }
        }
        _ => {}
    }
    S_OK
}

pub fn allow(phone: &str, gone: &AtomicBool) -> bool {
    let (title, main) = (wide("lidrop"), wide(&format!("Allow {phone} to connect?")));
    let text = wide("It will be remembered, and lidrop will connect to it automatically.");
    let (yes, no) = (wide("Allow"), wide("Don't Allow"));
    let buttons = [
        TASKDIALOG_BUTTON { nButtonID: ALLOW, pszButtonText: PCWSTR(yes.as_ptr()) },
        TASKDIALOG_BUTTON { nButtonID: DENY, pszButtonText: PCWSTR(no.as_ptr()) },
    ];
    let config = TASKDIALOGCONFIG {
        cbSize: size_of::<TASKDIALOGCONFIG>() as u32,
        dwFlags: TDF_CALLBACK_TIMER,
        pszWindowTitle: PCWSTR(title.as_ptr()),
        pszMainInstruction: PCWSTR(main.as_ptr()),
        pszContent: PCWSTR(text.as_ptr()),
        cButtons: buttons.len() as u32,
        pButtons: buttons.as_ptr(),
        nDefaultButton: ALLOW,
        pfCallback: Some(callback),
        lpCallbackData: gone as *const AtomicBool as isize,
        ..Default::default()
    };
    let mut picked = 0;
    if unsafe { TaskDialogIndirect(&config, Some(&mut picked), None, None) }.is_err() {
        let full = wide(&format!("Allow {phone} to connect?"));
        let plain = unsafe { MessageBoxW(None, PCWSTR(full.as_ptr()), PCWSTR(title.as_ptr()), MB_YESNO | MB_TOPMOST | MB_SETFOREGROUND) };
        return plain == IDYES && !gone.load(Ordering::Acquire);
    }
    picked == ALLOW && !gone.load(Ordering::Acquire)
}
