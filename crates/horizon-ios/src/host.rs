//! Where the game keeps its files on iOS, the overlay's attachment to winit's UIView,
//! and the per-server auto-login lookup hook.
use horizon_client_input::touch_bridge::{self, AutoLoginEntry};
use std::ffi::{CStr, CString, c_char};
use std::path::PathBuf;

unsafe extern "C" {
    /// objc/HorizonOverlayViewController.m: puts the native Bedrock overlay over winit's view.
    fn horizon_ios_attach_overlay(ui_view: *mut std::ffi::c_void);
    /// objc/HorizonAutoLoginStore.m: resolves enabled auto-login template + password + delay_ms.
    fn horizon_ios_lookup_autologin_parts(
        normalized_addr: *const c_char,
        tmpl_buf: *mut c_char,
        tmpl_buf_len: usize,
        pass_buf: *mut c_char,
        pass_buf_len: usize,
        out_delay_ms: *mut u64,
    ) -> bool;
    fn dup2(from: i32, to: i32) -> i32;
}

/// Before the game or pre-launcher starts, on the main thread with no other threads running.
///
/// - The game folder (saves, `options.txt`, `resources/`) is the app's Documents folder, which
///   the Files app and Finder show (`UIFileSharingEnabled` in Info.plist).
/// - Logs, crash reports and telemetry consent go in `Documents/horizon` (`HORIZON_HOME`), where
///   a player can find them to report a problem.
/// - The game's standard output and errors go to `Documents/horizon-log.txt`; the previous
///   launch's to `horizon-log.previous.txt`. iOS shows them nowhere else.
pub fn prepare() {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from);
    let documents = home.join("Documents");
    let horizon_home = documents.join("horizon");
    let _ = std::fs::create_dir_all(&documents);
    capture_output(&documents);
    for dir in [documents.join("resources"), horizon_home.clone()] {
        if let Err(error) = std::fs::create_dir_all(&dir) {
            eprintln!("horizon-ios: can't create {}: {error}", dir.display());
        }
    }
    eprintln!("horizon-ios: game folder {}", documents.display());
    // SAFETY: called first thing in `main`, before the game or any library starts a thread.
    unsafe {
        std::env::set_var("HORIZON_HOME", &horizon_home);
        std::env::set_var("RUST_BACKTRACE", "1");
    }
    if let Err(error) = std::env::set_current_dir(&documents) {
        eprintln!("horizon-ios: can't enter {}: {error}", documents.display());
    }
    touch_bridge::on_window_created(attach);
    touch_bridge::set_auto_login_lookup(lookup_auto_login);
}

/// Resolves per-server auto-login from `HorizonAutoLoginStore` and renders the command template.
/// Never logs passwords or rendered commands.
fn lookup_auto_login(normalized_addr: &str) -> Option<AutoLoginEntry> {
    let c_addr = CString::new(normalized_addr).ok()?;
    let mut tmpl_buf = [0u8; 512];
    let mut pass_buf = [0u8; 512];
    let mut delay_ms = 1000u64;
    // SAFETY: valid NUL-terminated `c_addr` and writable output buffers of declared sizes.
    let found = unsafe {
        horizon_ios_lookup_autologin_parts(
            c_addr.as_ptr(),
            tmpl_buf.as_mut_ptr().cast::<c_char>(),
            tmpl_buf.len(),
            pass_buf.as_mut_ptr().cast::<c_char>(),
            pass_buf.len(),
            &mut delay_ms,
        )
    };
    let result = if found {
        let tmpl = CStr::from_bytes_until_nul(&tmpl_buf)
            .ok()
            .and_then(|s| s.to_str().ok())
            .unwrap_or("/l {password}");
        let pass = CStr::from_bytes_until_nul(&pass_buf)
            .ok()
            .and_then(|s| s.to_str().ok())
            .unwrap_or("");
        touch_bridge::render_auto_login_command(tmpl, pass)
            .map(|command| AutoLoginEntry { command, delay_ms })
    } else {
        None
    };
    // Scrub password buffer before returning.
    for b in &mut pass_buf {
        // SAFETY: volatile write prevents dead-store elimination of the stack scrub.
        unsafe { std::ptr::write_volatile(b, 0) };
    }
    result
}

/// Points standard output and errors at `horizon-log.txt`, keeping the last launch's log.
fn capture_output(documents: &std::path::Path) {
    use std::os::fd::AsRawFd;
    let log = documents.join("horizon-log.txt");
    let _ = std::fs::rename(&log, documents.join("horizon-log.previous.txt"));
    let Ok(file) = std::fs::File::create(&log) else {
        return;
    };
    // SAFETY: dup2 onto the standard descriptors; `file` stays open until they are duplicated,
    // and the duplicates live for the rest of the process.
    unsafe {
        dup2(file.as_raw_fd(), 1);
        dup2(file.as_raw_fd(), 2);
    }
}

fn attach(window: &winit::window::Window) {
    use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
    let Ok(handle) = window.window_handle() else {
        return;
    };
    if let RawWindowHandle::UiKit(handle) = handle.as_raw() {
        // SAFETY: winit calls window creation on the main thread, and the view lives as long
        // as the window; the overlay keeps its own reference.
        unsafe { horizon_ios_attach_overlay(handle.ui_view.as_ptr()) };
    }
}
