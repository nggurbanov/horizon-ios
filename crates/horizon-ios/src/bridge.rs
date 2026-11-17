//! The Rust side of `objc/horizon_bridge.h`: Amethyst's `CallbackBridge_*` calls as Horizon's
//! touch input (`horizon_client_input::touch_bridge`). Called on the main thread only.
use crate::glfw;
use horizon_client_input::touch_bridge::{self, TouchInput};
use std::sync::Mutex;
use winit::event::{ElementState, MouseButton};

const ACTION_DOWN: i32 = 0;
const ACTION_UP: i32 = 1;
const ACTION_MOVE: i32 = 2;
const ACTION_MOVE_MOTION: i32 = 3;

/// The pointer as the game last heard it, and the last absolute touch point (Amethyst's
/// `cursorX`/`cursorY` and `cLastX`/`cLastY`).
struct Pointer {
    cursor: (f64, f64),
    last: (f64, f64),
}
static POINTER: Mutex<Pointer> = Mutex::new(Pointer {
    cursor: (0.0, 0.0),
    last: (0.0, 0.0),
});

fn state(action: i32) -> ElementState {
    if action == 0 {
        ElementState::Released
    } else {
        ElementState::Pressed
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn CallbackBridge_nativeSendKey(key: i32, _scancode: i32, action: i32, _mods: i32) {
    // A repeat (2) is a press: the game repeats held keys itself where vanilla does.
    if action == 2 {
        return;
    }
    if let Some(code) = glfw::key(key) {
        // Keys carry no text: what a key types comes through `nativeSendChar`, as GLFW's char
        // callback, so a hardware key doesn't type twice.
        touch_bridge::push(TouchInput::Key {
            code,
            state: state(action),
            text: None,
        });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn CallbackBridge_nativeSendChar(codepoint: u32) -> bool {
    match char::from_u32(codepoint) {
        Some(c) if !c.is_control() => {
            touch_bridge::push(TouchInput::Text(c.to_string()));
            true
        }
        _ => false,
    }
}

/// GLFW's char-with-modifiers callback: Amethyst sends it beside `nativeSendChar` for the same
/// character, so it types nothing here.
#[unsafe(no_mangle)]
pub extern "C" fn CallbackBridge_nativeSendCharMods(_codepoint: u32, _mods: i32) -> bool {
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn CallbackBridge_nativeSendMouseButton(button: i32, action: i32, _mods: i32) {
    let button = match button {
        0 => MouseButton::Left,
        1 => MouseButton::Right,
        2 => MouseButton::Middle,
        n if n > 2 => MouseButton::Other(n as u16),
        _ => return,
    };
    touch_bridge::push(TouchInput::Button {
        button,
        state: state(action),
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn CallbackBridge_nativeSendCursorPos(event: i32, x: f64, y: f64) {
    let Ok(mut pointer) = POINTER.lock() else {
        return;
    };
    let grabbing = touch_bridge::grabbing();
    match event {
        ACTION_MOVE_MOTION if grabbing => {
            touch_bridge::push(TouchInput::Look { dx: x, dy: y });
            return;
        }
        ACTION_MOVE_MOTION => {
            pointer.cursor.0 += x;
            pointer.cursor.1 += y;
        }
        ACTION_MOVE if grabbing => {
            let (dx, dy) = (x - pointer.last.0, y - pointer.last.1);
            pointer.last = (x, y);
            touch_bridge::push(TouchInput::Look { dx, dy });
            return;
        }
        ACTION_DOWN | ACTION_UP | ACTION_MOVE => {
            pointer.last = (x, y);
            if grabbing {
                return;
            }
            pointer.cursor = (x, y);
        }
        _ => return,
    }
    let (x, y) = pointer.cursor;
    touch_bridge::push(TouchInput::CursorTo { x, y });
}

#[unsafe(no_mangle)]
pub extern "C" fn CallbackBridge_nativeSendScroll(xoffset: f64, yoffset: f64) {
    touch_bridge::push(TouchInput::Scroll {
        dx: xoffset as f32,
        dy: yoffset as f32,
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn CallbackBridge_nativeSendScreenSize(_width: i32, _height: i32) {}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_is_grabbing() -> bool {
    touch_bridge::grabbing()
}

#[unsafe(no_mangle)]
pub extern "C" fn callback_SurfaceViewController_touchHotbar(x: f64, y: f64) -> i32 {
    touch_bridge::hotbar_slot(x, y).map_or(-1, |slot| glfw::KEY_1 + i32::from(slot))
}
