//! The Rust side of `objc/horizon_bridge.h`: connects the native UIKit / GameController /
//! CoreHaptics / CoreMotion overlay to `horizon_client_input::touch_bridge`.
//! All entry points are called on the iOS main thread.
use crate::hid;
use horizon_client_input::gamepad::{GlyphStyle, PadState};
use horizon_client_input::input_source::Feedback;
use horizon_client_input::touch_bridge::{
    self, InputMode, IosGamepadSnapshot, TouchFacts, TouchInput,
};
use std::ffi::{CStr, c_char};
use winit::event::{ElementState, MouseButton};

const FACT_FLYING: u32 = 1 << 0;
const FACT_MAY_FLY: u32 = 1 << 1;
const FACT_IN_WATER: u32 = 1 << 2;
const FACT_ON_GROUND: u32 = 1 << 3;
const FACT_GLIDING: u32 = 1 << 4;
const FACT_CAN_GLIDE: u32 = 1 << 5;
const FACT_RIDING: u32 = 1 << 6;
const FACT_VEHICLE_JUMPS: u32 = 1 << 7;
const FACT_SNEAKING: u32 = 1 << 8;
const FACT_SPRINTING: u32 = 1 << 9;
const FACT_SPECTATOR: u32 = 1 << 10;
const FACT_CREATIVE: u32 = 1 << 11;
const FACT_HANDS_BUSY: u32 = 1 << 12;
const FACT_CAN_SPRINT: u32 = 1 << 13;
const FACT_MAIN_HAND_ITEM: u32 = 1 << 14;
const FACT_OFF_HAND_ITEM: u32 = 1 << 15;
const FACT_TARGET_BLOCK: u32 = 1 << 16;
const FACT_TARGET_ENTITY: u32 = 1 << 17;

#[repr(C)]
pub struct HorizonOverlayState {
    pub grabbing: bool,
    pub screen_kind: u8,
    pub text_field_focused: bool,
    pub chat_open: bool,
    pub chat_revision: u64,
    pub has_hotbar: bool,
    pub selected_slot: u8,
    pub hotbar_x: f32,
    pub hotbar_y: f32,
    pub hotbar_w: f32,
    pub hotbar_h: f32,
    pub gui_scale: f32,
    pub mining_progress: f32,
    pub carrying_item: bool,
    pub facts_flags: u32,
    pub attack_kind: u8,
    pub use_verb: u8,
    pub active_use: u8,
}

#[repr(C)]
pub struct HorizonGamepadState {
    pub connected: bool,
    pub glyph_style: u8,
    pub buttons: u32,
    pub left_x: f32,
    pub left_y: f32,
    pub right_x: f32,
    pub right_y: f32,
    pub left_trigger: f32,
    pub right_trigger: f32,
    pub peak_left_x: f32,
    pub peak_left_y: f32,
    pub peak_right_x: f32,
    pub peak_right_y: f32,
    pub name: *const c_char,
}

#[repr(C)]
pub struct HorizonRumbleEvent {
    pub strong: f32,
    pub weak: f32,
    pub left_trigger: f32,
    pub right_trigger: f32,
    pub millis: u32,
}

#[repr(C)]
pub struct HorizonFeedbackEvent {
    pub kind: u8,
    pub intensity: f32,
}

fn glyph_style_from_u8(v: u8) -> GlyphStyle {
    match v {
        1 => GlyphStyle::Xbox,
        2 => GlyphStyle::PlayStation,
        3 => GlyphStyle::Nintendo,
        _ => GlyphStyle::Auto,
    }
}

fn pack_facts_flags(f: &TouchFacts) -> u32 {
    let mut bits = 0u32;
    if f.flying { bits |= FACT_FLYING; }
    if f.may_fly { bits |= FACT_MAY_FLY; }
    if f.in_water { bits |= FACT_IN_WATER; }
    if f.on_ground { bits |= FACT_ON_GROUND; }
    if f.gliding { bits |= FACT_GLIDING; }
    if f.can_glide { bits |= FACT_CAN_GLIDE; }
    if f.riding { bits |= FACT_RIDING; }
    if f.vehicle_jumps { bits |= FACT_VEHICLE_JUMPS; }
    if f.sneaking { bits |= FACT_SNEAKING; }
    if f.sprinting { bits |= FACT_SPRINTING; }
    if f.spectator { bits |= FACT_SPECTATOR; }
    if f.creative { bits |= FACT_CREATIVE; }
    if f.hands_busy { bits |= FACT_HANDS_BUSY; }
    if f.can_sprint { bits |= FACT_CAN_SPRINT; }
    if f.main_hand_item { bits |= FACT_MAIN_HAND_ITEM; }
    if f.off_hand_item { bits |= FACT_OFF_HAND_ITEM; }
    if f.target_is_block { bits |= FACT_TARGET_BLOCK; }
    if f.target_is_entity { bits |= FACT_TARGET_ENTITY; }
    bits
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_set_input_mode(mode: u8) {
    touch_bridge::set_active_input_mode(InputMode::from_u8(mode));
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_set_touch_move(active: bool, left: f32, forward: f32) {
    if active {
        touch_bridge::set_touch_move(Some([left, forward]));
    } else {
        touch_bridge::set_touch_move(None);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_set_hide_crosshair(hide: bool) {
    touch_bridge::set_hide_crosshair(hide);
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_set_touch_auto_jump(enabled: bool) {
    touch_bridge::set_touch_auto_jump(enabled);
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_set_keyboard_inset_px(px: f32) {
    touch_bridge::set_keyboard_inset_px(px);
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_send_key(hid_usage: u16, down: bool) {
    if let Some(code) = hid::key_from_hid(hid_usage) {
        touch_bridge::push_key(code, down);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_send_modifiers(mask: u8) {
    touch_bridge::push_explicit_modifiers(mask);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn horizon_ios_send_text(utf8: *const c_char) {
    if utf8.is_null() {
        return;
    }
    // SAFETY: caller passes a valid NUL-terminated UTF-8 C string on the main thread.
    if let Ok(s) = unsafe { CStr::from_ptr(utf8) }.to_str()
        && !s.is_empty()
    {
        touch_bridge::push(TouchInput::Text(s.to_owned()));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn horizon_ios_send_chat_text(utf8: *const c_char) {
    if utf8.is_null() {
        return;
    }
    // SAFETY: caller passes a valid NUL-terminated UTF-8 C string on the main thread.
    if let Ok(s) = unsafe { CStr::from_ptr(utf8) }.to_str() {
        touch_bridge::push(TouchInput::SetChatText(s.to_owned()));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_send_cursor(x: f64, y: f64) {
    touch_bridge::push(TouchInput::CursorTo { x, y });
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_send_mouse_button(button: u8, down: bool) {
    let button = match button {
        0 => MouseButton::Left,
        1 => MouseButton::Right,
        2 => MouseButton::Middle,
        n => MouseButton::Other(u16::from(n)),
    };
    touch_bridge::push(TouchInput::Button {
        button,
        state: if down {
            ElementState::Pressed
        } else {
            ElementState::Released
        },
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_send_look(dx: f64, dy: f64) {
    if dx.is_finite() && dy.is_finite() && (dx != 0.0 || dy != 0.0) {
        touch_bridge::push(TouchInput::Look { dx, dy });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_send_scroll(dx: f32, dy: f32) {
    if dx.is_finite() && dy.is_finite() && (dx != 0.0 || dy != 0.0) {
        touch_bridge::push(TouchInput::Scroll { dx, dy });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_tap_world(nx: f32, ny: f32) {
    if nx.is_finite() && ny.is_finite() {
        touch_bridge::push(TouchInput::TapWorld {
            x: nx.clamp(0.0, 1.0),
            y: ny.clamp(0.0, 1.0),
        });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_hold_world(nx: f32, ny: f32, active: bool) {
    if nx.is_finite() && ny.is_finite() {
        touch_bridge::push(TouchInput::HoldWorld {
            x: nx.clamp(0.0, 1.0),
            y: ny.clamp(0.0, 1.0),
            active,
        });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_move_world_hold(nx: f32, ny: f32) {
    if nx.is_finite() && ny.is_finite() {
        touch_bridge::push(TouchInput::MoveWorldHold {
            x: nx.clamp(0.0, 1.0),
            y: ny.clamp(0.0, 1.0),
        });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn horizon_ios_gamepad_update(state: *const HorizonGamepadState) {
    if state.is_null() {
        return;
    }
    // SAFETY: caller passes a valid pointer to `HorizonGamepadState`.
    let s = unsafe { &*state };
    let name = if s.name.is_null() {
        String::new()
    } else {
        // SAFETY: caller passes a NUL-terminated UTF-8 string when non-null.
        unsafe { CStr::from_ptr(s.name) }
            .to_str()
            .unwrap_or("Controller")
            .to_owned()
    };
    let pad = PadState {
        buttons: s.buttons,
        left: [s.left_x.clamp(-1.0, 1.0), s.left_y.clamp(-1.0, 1.0)],
        right: [s.right_x.clamp(-1.0, 1.0), s.right_y.clamp(-1.0, 1.0)],
        triggers: [
            s.left_trigger.clamp(0.0, 1.0),
            s.right_trigger.clamp(0.0, 1.0),
        ],
    };
    touch_bridge::set_ios_gamepad(IosGamepadSnapshot {
        connected: s.connected,
        state: pad,
        style: glyph_style_from_u8(s.glyph_style),
        name,
        peaks: [
            [s.peak_left_x.clamp(-1.0, 1.0), s.peak_left_y.clamp(-1.0, 1.0)],
            [s.peak_right_x.clamp(-1.0, 1.0), s.peak_right_y.clamp(-1.0, 1.0)],
        ],
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_gamepad_connection(connected: bool, glyph_style: u8) {
    touch_bridge::push_ios_gamepad_connection(connected, glyph_style_from_u8(glyph_style));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn horizon_ios_poll_state(
    out_state: *mut HorizonOverlayState,
    chat_buf: *mut c_char,
    chat_buf_len: usize,
) {
    if out_state.is_null() {
        return;
    }
    let st = touch_bridge::overlay_state();
    let (has_hotbar, selected_slot, rect) = match st.hotbar {
        Some(h) => (true, h.selected_slot, h.rect_px),
        None => (false, 0, [0.0; 4]),
    };
    let packed = HorizonOverlayState {
        grabbing: st.grabbing,
        screen_kind: st.screen_kind as u8,
        text_field_focused: st.text_field_focused,
        chat_open: st.chat_open,
        chat_revision: st.chat_revision,
        has_hotbar,
        selected_slot,
        hotbar_x: rect[0],
        hotbar_y: rect[1],
        hotbar_w: rect[2],
        hotbar_h: rect[3],
        gui_scale: st.gui_scale,
        mining_progress: st.mining_progress,
        carrying_item: st.carrying_item,
        facts_flags: pack_facts_flags(&st.facts),
        attack_kind: st.facts.attack_kind as u8,
        use_verb: st.facts.use_verb as u8,
        active_use: st.facts.using_active as u8,
    };
    // SAFETY: caller provides a writable `HorizonOverlayState`.
    unsafe { *out_state = packed };

    if !chat_buf.is_null() && chat_buf_len > 0 {
        let bytes = st.chat_text.as_bytes();
        let copy_len = bytes.len().min(chat_buf_len - 1);
        // Ensure we don't split a UTF-8 multi-byte character when truncating.
        let mut safe_len = copy_len;
        while safe_len > 0 && !st.chat_text.is_char_boundary(safe_len) {
            safe_len -= 1;
        }
        // SAFETY: `chat_buf` has capacity `chat_buf_len` bytes.
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), chat_buf.cast::<u8>(), safe_len);
            *chat_buf.add(safe_len) = 0;
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn horizon_ios_poll_rumble(out_rumble: *mut HorizonRumbleEvent) -> bool {
    if out_rumble.is_null() {
        return false;
    }
    let Some(cmd) = touch_bridge::pop_rumble() else {
        return false;
    };
    // SAFETY: caller provides a writable `HorizonRumbleEvent`.
    unsafe {
        *out_rumble = HorizonRumbleEvent {
            strong: cmd.strong,
            weak: cmd.weak,
            left_trigger: cmd.left_trigger,
            right_trigger: cmd.right_trigger,
            millis: cmd.millis,
        };
    }
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn horizon_ios_poll_feedback(
    out_feedback: *mut HorizonFeedbackEvent,
) -> bool {
    if out_feedback.is_null() {
        return false;
    }
    let Some(ev) = touch_bridge::pop_feedback() else {
        return false;
    };
    let (kind, intensity) = match ev {
        Feedback::BlockBroken => (1u8, 0.7),
        Feedback::Explosion { distance, radius } => {
            let max_d = (f64::from(radius.max(1.0)) * 4.0).max(8.0);
            let scale = (1.0 - (distance / max_d)).clamp(0.25, 1.0) as f32;
            (2u8, scale)
        }
        Feedback::Totem => (3u8, 1.0),
        Feedback::ItemStackSplit => (4u8, 0.45),
    };
    // SAFETY: caller provides a writable `HorizonFeedbackEvent`.
    unsafe {
        *out_feedback = HorizonFeedbackEvent { kind, intensity };
    }
    true
}
