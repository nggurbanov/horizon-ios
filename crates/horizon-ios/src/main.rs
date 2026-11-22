//! horizon-ios: the iOS app. Runs the official Horizon game (`horizon-official`) with a native
//! UIKit Bedrock touch, GameController, and hardware mouse+keyboard overlay (`objc/`).
//! See HORIZON-IOS.md.

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
fn main() {
    host::prepare();
    // UIKit needs the main thread, so the game stays on it, on a larger stack. winit's event
    // loop never returns on iOS: the app lives inside this call.
    stacker::grow(MAIN_STACK_BYTES, || {
        horizon_game::prepare_main_stack();
        std::hint::black_box(&GAME_IDENTITY);
        horizon_official::register();
        horizon_game::main();
    });
}

#[cfg(not(target_os = "ios"))]
fn main() {
    eprintln!("horizon-ios is the iOS app; on this system run horizon-official");
    std::process::exit(2);
}
