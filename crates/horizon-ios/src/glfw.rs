//! GLFW's key codes (what Amethyst's controls send) as winit's.
use winit::keyboard::KeyCode;

/// The winit key for a GLFW key code, or `None` for one with no key (`GLFW_KEY_UNKNOWN`, or
/// Amethyst's negative special buttons, which the overlay handles itself).
pub fn key(glfw: i32) -> Option<KeyCode> {
    use KeyCode as K;
    const LETTERS: [KeyCode; 26] = [
        K::KeyA, K::KeyB, K::KeyC, K::KeyD, K::KeyE, K::KeyF, K::KeyG, K::KeyH, K::KeyI, K::KeyJ,
        K::KeyK, K::KeyL, K::KeyM, K::KeyN, K::KeyO, K::KeyP, K::KeyQ, K::KeyR, K::KeyS, K::KeyT,
        K::KeyU, K::KeyV, K::KeyW, K::KeyX, K::KeyY, K::KeyZ,
    ];
    const DIGITS: [KeyCode; 10] = [
        K::Digit0, K::Digit1, K::Digit2, K::Digit3, K::Digit4, K::Digit5, K::Digit6, K::Digit7,
        K::Digit8, K::Digit9,
    ];
    const NUMPAD: [KeyCode; 10] = [
        K::Numpad0, K::Numpad1, K::Numpad2, K::Numpad3, K::Numpad4, K::Numpad5, K::Numpad6,
        K::Numpad7, K::Numpad8, K::Numpad9,
    ];
    const F: [KeyCode; 25] = [
        K::F1, K::F2, K::F3, K::F4, K::F5, K::F6, K::F7, K::F8, K::F9, K::F10, K::F11, K::F12,
        K::F13, K::F14, K::F15, K::F16, K::F17, K::F18, K::F19, K::F20, K::F21, K::F22, K::F23,
        K::F24, K::F25,
    ];
    Some(match glfw {
        32 => K::Space,
        39 => K::Quote,
        44 => K::Comma,
        45 => K::Minus,
        46 => K::Period,
        47 => K::Slash,
        48..=57 => DIGITS[(glfw - 48) as usize],
        59 => K::Semicolon,
        61 => K::Equal,
        65..=90 => LETTERS[(glfw - 65) as usize],
        91 => K::BracketLeft,
        92 => K::Backslash,
        93 => K::BracketRight,
        96 => K::Backquote,
        256 => K::Escape,
        257 => K::Enter,
        258 => K::Tab,
        259 => K::Backspace,
        260 => K::Insert,
        261 => K::Delete,
        262 => K::ArrowRight,
        263 => K::ArrowLeft,
        264 => K::ArrowDown,
        265 => K::ArrowUp,
        266 => K::PageUp,
        267 => K::PageDown,
        268 => K::Home,
        269 => K::End,
        280 => K::CapsLock,
        281 => K::ScrollLock,
        282 => K::NumLock,
        283 => K::PrintScreen,
        284 => K::Pause,
        290..=314 => F[(glfw - 290) as usize],
        320..=329 => NUMPAD[(glfw - 320) as usize],
        330 => K::NumpadDecimal,
        331 => K::NumpadDivide,
        332 => K::NumpadMultiply,
        333 => K::NumpadSubtract,
        334 => K::NumpadAdd,
        335 => K::NumpadEnter,
        336 => K::NumpadEqual,
        340 => K::ShiftLeft,
        341 => K::ControlLeft,
        342 => K::AltLeft,
        343 => K::SuperLeft,
        344 => K::ShiftRight,
        345 => K::ControlRight,
        346 => K::AltRight,
        347 => K::SuperRight,
        348 => K::ContextMenu,
        _ => return None,
    })
}

/// GLFW's first number-row key: hotbar slot `n` is `GLFW_KEY_1 + n`.
pub const KEY_1: i32 = 49;
