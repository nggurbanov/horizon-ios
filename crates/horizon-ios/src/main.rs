//! horizon-ios: the iOS app. Runs the Horizon game (`horizon-game`) with a native UIKit
//! landscape Pre-Launcher and Bedrock touch, GameController, and hardware mouse+keyboard
//! overlay (`objc/`). See HORIZON-IOS.md.

#[cfg(target_os = "ios")]
mod bridge;
#[cfg(target_os = "ios")]
mod hid;
#[cfg(target_os = "ios")]
mod host;

/// The game identity marker for launcher imports, retained by `main`.
#[cfg(target_os = "ios")]
static GAME_IDENTITY: [u8; horizon_game::GAME_IDENTITY.len()] = horizon_game::GAME_IDENTITY;

/// The stack the game runs on. Desktop builds give the main thread 136 MiB at link time
/// (packaging/executable_link.rs); iOS gives it 1 MiB whatever the executable asks, and inside
/// LiveContainer the game runs on LiveContainer's main thread. Only the pages used take memory.
#[cfg(target_os = "ios")]
const MAIN_STACK_BYTES: usize = 64 * 1024 * 1024;

#[cfg(target_os = "ios")]
unsafe extern "C" {
    /// objc/HorizonPreLauncherAppDelegate.m: shows the native UIKit pre-launcher (or invokes
    /// `launch_cb` immediately when `skipLauncher` is YES and `horizon-resources.json` exists).
    fn horizon_ios_run_prelauncher_or_launch(launch_cb: extern "C" fn());
}

#[cfg(target_os = "ios")]
extern "C" fn launch_game_entry() {
    horizon_game::prepare_main_stack();
    std::hint::black_box(&GAME_IDENTITY);
    horizon_game::main();
}

#[cfg(target_os = "ios")]
fn main() {
    host::prepare();
    // UIKit needs the main thread, so both the pre-launcher and the game stay on it, on a larger
    // stack. Neither UIApplicationMain nor winit's event loop returns on iOS.
    stacker::grow(MAIN_STACK_BYTES, || {
        // SAFETY: invoked once on the main thread inside the 64 MiB stack frame.
        unsafe { horizon_ios_run_prelauncher_or_launch(launch_game_entry) };
    });
}

#[cfg(not(target_os = "ios"))]
fn main() {
    eprintln!("horizon-ios is the iOS app; on this system run horizon-client");
    std::process::exit(2);
}
