//! Where the game keeps its files on iOS, and the touch overlay's attachment to its window.
use std::path::PathBuf;

unsafe extern "C" {
    /// objc/HorizonSurfaceViewController.m: puts the touch controls over winit's view.
    fn horizon_ios_attach_overlay(ui_view: *mut std::ffi::c_void);
}

/// Before the game starts, on the main thread with no other threads running.
///
/// - The game folder (saves, `options.txt`, `resources/`) is the app's Documents folder, which
///   the Files app and Finder show (`UIFileSharingEnabled` in Info.plist).
/// - Logs, crash reports and telemetry consent go in Application Support (`HORIZON_HOME`).
/// - Amethyst's control layouts go in `Documents/controlmap` (`AME_HOME`).
pub fn prepare() {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from);
    let documents = home.join("Documents");
    let support = home.join("Library/Application Support/Horizon");
    for dir in [documents.join("resources"), documents.join("controlmap"), support.clone()] {
        if let Err(error) = std::fs::create_dir_all(&dir) {
            eprintln!("horizon-ios: can't create {}: {error}", dir.display());
        }
    }
    // SAFETY: called first thing in `main`, before the game or any library starts a thread.
    unsafe {
        std::env::set_var("HORIZON_HOME", &support);
        std::env::set_var("AME_HOME", &documents);
    }
    if let Err(error) = std::env::set_current_dir(&documents) {
        eprintln!("horizon-ios: can't enter {}: {error}", documents.display());
    }
    horizon_client_input::touch_bridge::on_window_created(attach);
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
