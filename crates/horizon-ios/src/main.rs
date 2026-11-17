//! horizon-ios: the iOS app. The official game (`horizon-official`) with Amethyst-iOS's touch
//! controls over its view (`objc/`, GPL-3.0). See HORIZON-IOS.md.

#[cfg(target_os = "ios")]
mod bridge;
#[cfg(target_os = "ios")]
mod glfw;
#[cfg(target_os = "ios")]
mod host;

/// The game identity marker for launcher imports, retained by `main`.
#[cfg(target_os = "ios")]
static GAME_IDENTITY: [u8; horizon_game::GAME_IDENTITY.len()] = horizon_game::GAME_IDENTITY;

#[cfg(target_os = "ios")]
fn main() {
    host::prepare();
    horizon_game::prepare_main_stack();
    std::hint::black_box(&GAME_IDENTITY);
    horizon_official::register();
    horizon_game::main();
}

#[cfg(not(target_os = "ios"))]
fn main() {
    eprintln!("horizon-ios is the iOS app; on this system run horizon-official");
    std::process::exit(2);
}
