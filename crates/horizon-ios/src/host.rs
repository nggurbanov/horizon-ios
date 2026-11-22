//! Where the game keeps its files on iOS, and the overlay's attachment to winit's UIView.
use std::path::PathBuf;

unsafe extern "C" {
    /// objc/HorizonOverlayViewController.m: puts the native Bedrock overlay over winit's view.
    fn horizon_ios_attach_overlay(ui_view: *mut std::ffi::c_void);
    fn dup2(from: i32, to: i32) -> i32;
}

/// Before the game starts, on the main thread with no other threads running.
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
    horizon_client_input::touch_bridge::on_window_created(attach);
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
