//! horizon-ios: native input bridge between the iOS UIKit / GameController host and Horizon.
//!
//! Coordinates three seamless input modes (`Touch`, `Gamepad`, `KeyboardMouse`):
//! - Touch controls, hardware keyboard (`GCKeyboard`/`UIPress`), and mouse (`GCMouse`) push
//!   `TouchInput` events here from the main thread; the game drains them once per event-loop pass
//!   (`Game::take_touch_input`).
//! - The touch joystick feeds an analog `[left, forward]` vector separately from `Pads`, so
//!   touch controls never flip `Pads::in_use` into console mode.
//! - Native Apple `GCController` snapshots flow into Horizon's `Pads` engine so all console
//!   features (analog sticks, glyphs, gameplay guide, inventory snapping, radial menu, haptics)
//!   work natively on iOS.
//! - Every frame the game publishes `OverlayState` (screen kind, `gameplay_guide::Facts`, exact
//!   hotbar rect, mining progress, text-field focus, chat buffer) for the Bedrock touch HUD,
//!   alongside `Feedback` and `RumbleCommand` queues for native CoreHaptics / UIImpactFeedback.
//!
//! On desktop nothing pushes and every queue stays empty.
use crate::gamepad::{GlyphStyle, PadState};
use crate::gameplay_guide::{Active, Facts, Target, Verb};
use crate::input_source::Feedback;
use std::collections::VecDeque;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU32, Ordering};
use winit::event::{ElementState, MouseButton};
use winit::keyboard::KeyCode;

/// Which input family currently owns the game on iOS (instant auto-switching like Bedrock).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum InputMode {
    #[default]
    Touch = 0,
    Gamepad = 1,
    KeyboardMouse = 2,
}

impl InputMode {
    pub fn from_u8(value: u8) -> Self {
        match value {
            1 => Self::Gamepad,
            2 => Self::KeyboardMouse,
            _ => Self::Touch,
        }
    }
}

/// High-level screen category for choosing the right Bedrock mobile HUD layer.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum ScreenKind {
    #[default]
    Menu = 0,
    Playing = 1,
    Inventory = 2,
    Creative = 3,
    Container = 4,
    Chat = 5,
    Loading = 6,
}

/// What the Attack / Break button would act on right now.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum AttackKind {
    #[default]
    None = 0,
    Break = 1,
    Attack = 2,
    Spectate = 3,
}

/// What the Interact / Use button would do right now, matching `gameplay_guide::Verb`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum UseVerb {
    #[default]
    None = 0,
    Use = 1,
    Open = 2,
    Ride = 3,
    Trade = 4,
    Feed = 5,
    Place = 6,
    Eat = 7,
    Drink = 8,
    Shoot = 9,
    Load = 10,
    Throw = 11,
    Raise = 12,
    Equip = 13,
    Fish = 14,
    Zoom = 15,
    Boost = 16,
}

impl From<Verb> for UseVerb {
    fn from(verb: Verb) -> Self {
        match verb {
            Verb::Use => Self::Use,
            Verb::Open => Self::Open,
            Verb::Ride => Self::Ride,
            Verb::Trade => Self::Trade,
            Verb::Feed => Self::Feed,
            Verb::Place => Self::Place,
            Verb::Eat => Self::Eat,
            Verb::Drink => Self::Drink,
            Verb::Shoot => Self::Shoot,
            Verb::Load => Self::Load,
            Verb::Throw => Self::Throw,
            Verb::Raise => Self::Raise,
            Verb::Equip => Self::Equip,
            Verb::Fish => Self::Fish,
            Verb::Zoom => Self::Zoom,
            Verb::Boost => Self::Boost,
        }
    }
}

/// What an actively held item (`LivingEntity.isUsingItem`) does when released.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum ActiveUse {
    #[default]
    None = 0,
    Shoot = 1,
    Throw = 2,
    Stop = 3,
}

impl From<Active> for ActiveUse {
    fn from(active: Active) -> Self {
        match active {
            Active::Shoot => Self::Shoot,
            Active::Throw => Self::Throw,
            Active::Stop => Self::Stop,
        }
    }
}

/// Gameplay context exported to the native iOS touch overlay for contextual Bedrock buttons.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TouchFacts {
    pub flying: bool,
    pub may_fly: bool,
    pub in_water: bool,
    pub on_ground: bool,
    pub gliding: bool,
    pub can_glide: bool,
    pub riding: bool,
    pub vehicle_jumps: bool,
    pub sneaking: bool,
    pub sprinting: bool,
    pub spectator: bool,
    pub creative: bool,
    pub hands_busy: bool,
    pub can_sprint: bool,
    pub main_hand_item: bool,
    pub off_hand_item: bool,
    pub using_active: ActiveUse,
    pub attack_kind: AttackKind,
    pub use_verb: UseVerb,
    pub target_is_block: bool,
    pub target_is_entity: bool,
}

impl TouchFacts {
    /// Distills Horizon's `gameplay_guide::Facts` into the compact context needed by touch HUD.
    pub fn from_guide(
        facts: &Facts,
        sneaking: bool,
        sprinting: bool,
        creative: bool,
    ) -> Self {
        let attack_kind = if facts.using.is_some() || facts.hands_busy {
            AttackKind::None
        } else {
            match facts.target {
                Target::Entity {
                    attackable: true, ..
                } if facts.spectator => AttackKind::Spectate,
                Target::Entity {
                    attackable: true, ..
                } => AttackKind::Attack,
                Target::Block {
                    breakable: true, ..
                } => AttackKind::Break,
                _ => AttackKind::None,
            }
        };
        let target_takes = match facts.target {
            Target::Block { takes, .. } | Target::Entity { takes, .. } => takes,
            Target::None => None,
        };
        let use_verb = if facts.hands_busy {
            UseVerb::None
        } else {
            target_takes
                .or(facts.item_use)
                .map_or(UseVerb::None, UseVerb::from)
        };
        Self {
            flying: facts.flying,
            may_fly: facts.may_fly,
            in_water: facts.in_water,
            on_ground: facts.on_ground,
            gliding: facts.gliding,
            can_glide: facts.can_glide,
            riding: facts.riding,
            vehicle_jumps: facts.vehicle_jumps,
            sneaking,
            sprinting,
            spectator: facts.spectator,
            creative,
            hands_busy: facts.hands_busy,
            can_sprint: facts.can_sprint,
            main_hand_item: facts.main_hand_item,
            off_hand_item: facts.off_hand_item,
            using_active: facts.using.map_or(ActiveUse::None, ActiveUse::from),
            attack_kind,
            use_verb,
            target_is_block: matches!(facts.target, Target::Block { .. }),
            target_is_entity: matches!(facts.target, Target::Entity { .. }),
        }
    }
}

/// Exact physical-pixel hotbar geometry from vanilla's `Gui.renderHotbar` (182x22 GUI px).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct HotbarMetrics {
    pub view_size: [u32; 2],
    pub gui_scale: f32,
    pub selected_slot: u8,
    /// `[x, y, width, height]` in physical pixels.
    pub rect_px: [f32; 4],
}

impl HotbarMetrics {
    pub fn from_view(view_size: [u32; 2], gui_scale: f32, selected_slot: u8) -> Self {
        let scale = gui_scale.max(1.0);
        let width_gui = view_size[0] as f32 / scale;
        let height_gui = view_size[1] as f32 / scale;
        let left_gui = (width_gui - 182.0) / 2.0;
        let top_gui = height_gui - 22.0;
        Self {
            view_size,
            gui_scale: scale,
            selected_slot: selected_slot.min(8),
            rect_px: [
                left_gui * scale,
                top_gui * scale,
                182.0 * scale,
                22.0 * scale,
            ],
        }
    }

    /// The hotbar slot (`0..=8`) under a physical-pixel point, if inside the bar.
    pub fn slot_at(&self, x: f64, y: f64) -> Option<u8> {
        if self.gui_scale <= 0.0 {
            return None;
        }
        let (gx, gy) = (x as f32 / self.gui_scale, y as f32 / self.gui_scale);
        let left = (self.view_size[0] as f32 / self.gui_scale - 182.0) / 2.0;
        let top = self.view_size[1] as f32 / self.gui_scale - 22.0;
        if gy < top || gx < left || gx >= left + 182.0 {
            return None;
        }
        Some((((gx - left - 1.0) / 20.0).floor().clamp(0.0, 8.0)) as u8)
    }
}

/// Complete game-to-overlay snapshot published once per event-loop pass.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct OverlayState {
    pub grabbing: bool,
    pub screen_kind: ScreenKind,
    pub text_field_focused: bool,
    pub chat_open: bool,
    pub chat_text: String,
    pub chat_revision: u64,
    pub hotbar: Option<HotbarMetrics>,
    pub facts: TouchFacts,
    pub mining_progress: f32,
    pub carrying_item: bool,
    pub gui_scale: f32,
}

/// One input from the iOS overlay, hardware keyboard, or hardware mouse.
#[derive(Clone, Debug, PartialEq)]
pub enum TouchInput {
    /// A key pressed or let go. `text` is what it types when pressed, or `None` for keys that
    /// type nothing.
    Key {
        code: KeyCode,
        state: ElementState,
        text: Option<String>,
    },
    /// Live keyboard modifier state (Shift/Ctrl/Alt/Super) for inventory quick-move, drop stack,
    /// and hardware keyboards.
    Modifiers {
        shift: bool,
        ctrl: bool,
        alt: bool,
        super_key: bool,
    },
    /// Text typed with no physical key (the on-screen keyboard's characters / paste).
    Text(String),
    /// Replaces the open `ChatScreen` input buffer from the native iOS top chat `UITextField`.
    SetChatText(String),
    /// The pointer moved to this point of the view, in physical pixels.
    CursorTo { x: f64, y: f64 },
    /// A mouse button pressed or let go at the pointer.
    Button {
        button: MouseButton,
        state: ElementState,
    },
    /// The view turned, as a grabbed mouse moving by this many pixels.
    Look { dx: f64, dy: f64 },
    /// The wheel scrolled by lines (vanilla's hotbar scroll / list scroll).
    Scroll { dx: f32, dy: f32 },
    /// Tap-to-Interact: short tap on the world at normalized surface coords `[0..1, 0..1]`
    /// (origin top-left, y down). The game raycasts through that point and interacts/places or
    /// attacks accordingly.
    TapWorld { x: f32, y: f32 },
    /// Tap-to-Interact: long hold started (`active = true`) or ended (`active = false`) at
    /// normalized surface coords `[0..1, 0..1]`.
    HoldWorld { x: f32, y: f32, active: bool },
    /// Tap-to-Interact: live finger position update while holding, so sliding to a neighboring
    /// block retargets mining cleanly.
    MoveWorldHold { x: f32, y: f32 },
}

/// Snapshot of the active native iOS `GCController` for Horizon's `Pads` engine.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct IosGamepadSnapshot {
    pub connected: bool,
    pub state: PadState,
    pub style: GlyphStyle,
    pub name: String,
    pub peaks: [[f32; 2]; 2],
}

/// Controller connect/disconnect edge from `GCController` notifications.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IosGamepadConnection {
    pub connected: bool,
    pub style: GlyphStyle,
}

/// Controller rumble pulse forwarded from Horizon's `Pads` to `GCController.haptics`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RumbleCommand {
    pub strong: f32,
    pub weak: f32,
    pub left_trigger: f32,
    pub right_trigger: f32,
    pub millis: u32,
}

static QUEUE: Mutex<VecDeque<TouchInput>> = Mutex::new(VecDeque::new());
static GRABBING: AtomicBool = AtomicBool::new(false);
static ACTIVE_INPUT_MODE: AtomicU8 = AtomicU8::new(InputMode::Touch as u8);
static HIDE_CROSSHAIR: AtomicBool = AtomicBool::new(false);
static TOUCH_AUTO_JUMP: AtomicBool = AtomicBool::new(true);
static KEYBOARD_INSET_BITS: AtomicU32 = AtomicU32::new(0);
// horizon-ios: held modifier keys (8 bits matching USB HID 0xE0..=0xE7) tracked separately from
// the 4-bit explicit modifier mask so touch Sneak/Sprint keys and synthetic Quick-Move/Drop
// modifiers never clobber each other or get wiped by `Game::heal_hold_latches`.
static KEY_MOD_BITS: AtomicU8 = AtomicU8::new(0);
static EXPLICIT_MOD_MASK: AtomicU8 = AtomicU8::new(0);
static TOUCH_MOVE: Mutex<Option<[f32; 2]>> = Mutex::new(None);
static HOTBAR: Mutex<Option<HotbarMetrics>> = Mutex::new(None);
static OVERLAY_STATE: Mutex<Option<OverlayState>> = Mutex::new(None);
static IOS_GAMEPAD: Mutex<Option<IosGamepadSnapshot>> = Mutex::new(None);
static IOS_GAMEPAD_CONNS: Mutex<VecDeque<IosGamepadConnection>> = Mutex::new(VecDeque::new());
static RUMBLE_QUEUE: Mutex<VecDeque<RumbleCommand>> = Mutex::new(VecDeque::new());
static FEEDBACK_QUEUE: Mutex<VecDeque<Feedback>> = Mutex::new(VecDeque::new());
static WINDOW_CREATED: Mutex<Option<fn(&winit::window::Window)>> = Mutex::new(None);

/// Explicit modifier bit masks matching `HORIZON_MOD_*` in `horizon_bridge.h`.
pub const MOD_SHIFT: u8 = 1 << 0;
pub const MOD_CTRL: u8 = 1 << 1;
pub const MOD_ALT: u8 = 1 << 2;
pub const MOD_SUPER: u8 = 1 << 3;

fn modifier_key_bit(code: KeyCode) -> Option<u8> {
    Some(match code {
        KeyCode::ControlLeft => 1 << 0,
        KeyCode::ShiftLeft => 1 << 1,
        KeyCode::AltLeft => 1 << 2,
        KeyCode::SuperLeft => 1 << 3,
        KeyCode::ControlRight => 1 << 4,
        KeyCode::ShiftRight => 1 << 5,
        KeyCode::AltRight => 1 << 6,
        KeyCode::SuperRight => 1 << 7,
        _ => return None,
    })
}

fn key_bits_to_mod_mask(key_bits: u8) -> u8 {
    let mut mask = 0u8;
    if (key_bits & ((1 << 1) | (1 << 5))) != 0 {
        mask |= MOD_SHIFT;
    }
    if (key_bits & ((1 << 0) | (1 << 4))) != 0 {
        mask |= MOD_CTRL;
    }
    if (key_bits & ((1 << 2) | (1 << 6))) != 0 {
        mask |= MOD_ALT;
    }
    if (key_bits & ((1 << 3) | (1 << 7))) != 0 {
        mask |= MOD_SUPER;
    }
    mask
}

fn effective_modifiers(key_bits: u8, explicit_mask: u8) -> TouchInput {
    let mask = key_bits_to_mod_mask(key_bits) | (explicit_mask & 0x0F);
    TouchInput::Modifiers {
        shift: (mask & MOD_SHIFT) != 0,
        ctrl: (mask & MOD_CTRL) != 0,
        alt: (mask & MOD_ALT) != 0,
        super_key: (mask & MOD_SUPER) != 0,
    }
}

/// Pushes a physical/touch key event and keeps live `TouchInput::Modifiers` synchronized for
/// modifier keys so `Game::heal_hold_latches` preserves touch Shift/Ctrl holds.
///
/// Matches native macOS/winit ordering: on press, `Modifiers` precedes `Key { Pressed }`;
/// on release, `Key { Released }` precedes the updated `Modifiers`.
pub fn push_key(code: KeyCode, down: bool) {
    let key_event = TouchInput::Key {
        code,
        state: if down {
            ElementState::Pressed
        } else {
            ElementState::Released
        },
        text: None,
    };
    match (modifier_key_bit(code), down) {
        (Some(bit), true) => {
            let key_bits = KEY_MOD_BITS.fetch_or(bit, Ordering::AcqRel) | bit;
            let explicit = EXPLICIT_MOD_MASK.load(Ordering::Acquire);
            push(effective_modifiers(key_bits, explicit));
            push(key_event);
        }
        (Some(bit), false) => {
            let key_bits = KEY_MOD_BITS.fetch_and(!bit, Ordering::AcqRel) & !bit;
            let explicit = EXPLICIT_MOD_MASK.load(Ordering::Acquire);
            push(key_event);
            push(effective_modifiers(key_bits, explicit));
        }
        (None, _) => {
            push(key_event);
        }
    }
}

/// Updates the 4-bit explicit modifier mask (e.g. inventory Quick Move Shift or hotbar Ctrl+Q)
/// and emits the combined `TouchInput::Modifiers` without clobbering held modifier keys.
pub fn push_explicit_modifiers(mask: u8) {
    let explicit = mask & 0x0F;
    EXPLICIT_MOD_MASK.store(explicit, Ordering::Release);
    let key_bits = KEY_MOD_BITS.load(Ordering::Acquire);
    push(effective_modifiers(key_bits, explicit));
}

/// Writes the first `limit` of a kind of event to the log (`Documents/horizon-log.txt` on iOS),
/// so a report shows how far input got without spamming the log.
fn trace(count: &AtomicU32, limit: u32, line: impl FnOnce() -> String) {
    if count.fetch_add(1, Ordering::Relaxed) < limit {
        eprintln!("horizon-ios: {}", line());
    }
}

/// Adds an input for the next event-loop pass.
pub fn push(input: TouchInput) {
    static PUSHED: AtomicU32 = AtomicU32::new(0);
    trace(&PUSHED, 40, || format!("touch input {input:?}"));
    if let Ok(mut queue) = QUEUE.lock() {
        // A stalled game must not grow the queue without end.
        if queue.len() < 4096 {
            queue.push_back(input);
        }
    }
}

/// The inputs since the last call, oldest first.
pub fn take() -> Vec<TouchInput> {
    static TAKEN: AtomicU32 = AtomicU32::new(0);
    let inputs: Vec<TouchInput> = QUEUE
        .lock()
        .map(|mut queue| queue.drain(..).collect())
        .unwrap_or_default();
    if !inputs.is_empty() {
        trace(&TAKEN, 20, || {
            format!("the game took {} touch inputs", inputs.len())
        });
    }
    inputs
}

/// Active iOS input mode (`Touch`, `Gamepad`, `KeyboardMouse`).
pub fn active_input_mode() -> InputMode {
    InputMode::from_u8(ACTIVE_INPUT_MODE.load(Ordering::Relaxed))
}

/// Switches the active iOS input mode. Clearing touch move when leaving Touch prevents drift.
pub fn set_active_input_mode(mode: InputMode) {
    let prev = ACTIVE_INPUT_MODE.swap(mode as u8, Ordering::Relaxed);
    if prev != mode as u8 {
        if mode != InputMode::Touch {
            set_touch_move(None);
        }
        eprintln!("horizon-ios: input mode -> {mode:?}");
    }
}

/// Analog movement vector `[left, forward]` (`-1..1`, length <= 1) from the touch joystick/D-pad,
/// kept separate from `Pads` so touch play never turns on controller UI/hints.
pub fn set_touch_move(vector: Option<[f32; 2]>) {
    let sanitized = vector.and_then(|[left, forward]| {
        if !left.is_finite() || !forward.is_finite() {
            return None;
        }
        let len = (left * left + forward * forward).sqrt();
        if len < 1e-4 {
            return None;
        }
        let clamped = if len > 1.0 {
            [left / len, forward / len]
        } else {
            [left, forward]
        };
        Some(clamped)
    });
    if let Ok(mut slot) = TOUCH_MOVE.lock() {
        *slot = sanitized;
    }
}

/// Current analog touch movement vector `[left, forward]`, if non-zero.
pub fn touch_move() -> Option<[f32; 2]> {
    TOUCH_MOVE.lock().ok().and_then(|slot| *slot)
}

/// Whether the center crosshair should be hidden (Touch mode in Tap-to-Interact schemes).
pub fn hide_crosshair() -> bool {
    HIDE_CROSSHAIR.load(Ordering::Relaxed)
}

pub fn set_hide_crosshair(hide: bool) {
    HIDE_CROSSHAIR.store(hide, Ordering::Relaxed);
}

/// Whether Bedrock Touch Auto-Jump is enabled while playing in Touch mode.
pub fn touch_auto_jump() -> bool {
    TOUCH_AUTO_JUMP.load(Ordering::Relaxed)
}

pub fn set_touch_auto_jump(enabled: bool) {
    TOUCH_AUTO_JUMP.store(enabled, Ordering::Relaxed);
}

/// Height in physical pixels currently covered by the on-screen iOS keyboard (0 when hidden).
pub fn keyboard_inset_px() -> f32 {
    f32::from_bits(KEYBOARD_INSET_BITS.load(Ordering::Relaxed))
}

pub fn set_keyboard_inset_px(px: f32) {
    let clamped = if px.is_finite() && px > 0.0 { px } else { 0.0 };
    KEYBOARD_INSET_BITS.store(clamped.to_bits(), Ordering::Relaxed);
}

/// Whether the game holds the pointer (playing, no screen open).
pub fn grabbing() -> bool {
    GRABBING.load(Ordering::Relaxed)
}

/// The game says whether it holds the pointer, once per event-loop pass.
pub fn set_grabbing(grabbing: bool) {
    GRABBING.store(grabbing, Ordering::Relaxed);
}

/// The game says where vanilla's hotbar is drawn, once per event-loop pass: the view's size in
/// physical pixels and the GUI scale, or `None` while no hotbar shows.
pub fn set_hotbar(view: Option<([u32; 2], f32)>) {
    set_hotbar_metrics(view.map(|(size, scale)| HotbarMetrics::from_view(size, scale, 0)));
}

/// Updates the exact hotbar geometry and selected slot.
pub fn set_hotbar_metrics(metrics: Option<HotbarMetrics>) {
    if let Ok(mut slot) = HOTBAR.lock() {
        *slot = metrics;
    }
}

/// The hotbar slot (0 to 8) under a point of the view in physical pixels (`Gui.renderHotbar`:
/// 182 by 22 GUI pixels, centred at the bottom, 20 per slot after a 1-pixel border).
pub fn hotbar_slot(x: f64, y: f64) -> Option<u8> {
    let metrics = (*HOTBAR.lock().ok()?)?;
    metrics.slot_at(x, y)
}

/// Publishes the full game state snapshot for the iOS overlay.
pub fn set_overlay_state(state: OverlayState) {
    GRABBING.store(state.grabbing, Ordering::Relaxed);
    set_hotbar_metrics(state.hotbar);
    if let Ok(mut slot) = OVERLAY_STATE.lock() {
        *slot = Some(state);
    }
}

/// Reads the latest game state snapshot for the iOS overlay.
pub fn overlay_state() -> OverlayState {
    OVERLAY_STATE
        .lock()
        .ok()
        .and_then(|slot| slot.clone())
        .unwrap_or_default()
}

/// Updates the active native iOS `GCController` state (accumulating peak stick deflections so
/// fast flicks between game polls still reach the radial menu).
pub fn set_ios_gamepad(snapshot: IosGamepadSnapshot) {
    if let Ok(mut slot) = IOS_GAMEPAD.lock() {
        let mut merged = snapshot;
        if let Some(prev) = slot.as_ref()
            && prev.connected
            && merged.connected
        {
            for i in 0..2 {
                let prev_len = prev.peaks[i][0].hypot(prev.peaks[i][1]);
                let next_len = merged.peaks[i][0].hypot(merged.peaks[i][1]);
                if prev_len > next_len {
                    merged.peaks[i] = prev.peaks[i];
                }
            }
        }
        *slot = Some(merged);
    }
}

/// Reads the latest `GCController` snapshot and resets accumulated inter-poll stick peaks.
pub fn take_ios_gamepad_snapshot() -> Option<IosGamepadSnapshot> {
    let mut slot = IOS_GAMEPAD.lock().ok()?;
    let current = slot.clone()?;
    if let Some(stored) = slot.as_mut() {
        stored.peaks = [stored.state.left, stored.state.right];
    }
    Some(current)
}

/// Records a `GCController` connect or disconnect notification.
pub fn push_ios_gamepad_connection(connected: bool, style: GlyphStyle) {
    if let Ok(mut queue) = IOS_GAMEPAD_CONNS.lock()
        && queue.len() < 64
    {
        queue.push_back(IosGamepadConnection { connected, style });
    }
}

/// Drains pending `GCController` connection changes for Horizon's connection notice.
pub fn take_ios_gamepad_connections() -> Vec<IosGamepadConnection> {
    IOS_GAMEPAD_CONNS
        .lock()
        .map(|mut queue| queue.drain(..).collect())
        .unwrap_or_default()
}

/// Queues a gamepad vibration command for `GCController.haptics`.
pub fn push_rumble(cmd: RumbleCommand) {
    if let Ok(mut queue) = RUMBLE_QUEUE.lock() {
        if queue.len() >= 32 {
            queue.pop_front();
        }
        queue.push_back(cmd);
    }
}

/// Pops the oldest pending gamepad rumble command.
pub fn pop_rumble() -> Option<RumbleCommand> {
    RUMBLE_QUEUE.lock().ok()?.pop_front()
}

/// Queues a gameplay haptic event (`BlockBroken`, `Explosion`, `Totem`, `ItemStackSplit`) for
/// native iOS touch haptics.
pub fn push_feedback(event: Feedback) {
    if let Ok(mut queue) = FEEDBACK_QUEUE.lock() {
        if queue.len() >= 32 {
            queue.pop_front();
        }
        queue.push_back(event);
    }
}

/// Pops the oldest pending gameplay haptic event.
pub fn pop_feedback() -> Option<Feedback> {
    FEEDBACK_QUEUE.lock().ok()?.pop_front()
}

/// The host's hook for a newly created game window: the iOS host puts its overlay over
/// the window's view there. Set it before the game starts.
pub fn on_window_created(hook: fn(&winit::window::Window)) {
    if let Ok(mut slot) = WINDOW_CREATED.lock() {
        *slot = Some(hook);
    }
}

/// The game created its window.
pub fn window_created(window: &winit::window::Window) {
    let hook = WINDOW_CREATED.lock().ok().and_then(|slot| *slot);
    eprintln!(
        "horizon-ios: game window created (overlay hook set: {})",
        hook.is_some()
    );
    if let Some(hook) = hook {
        hook(window);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        keybinds::KeyBinds,
        keymapping::{KeyAction, SNEAK, SPRINT, ToggleKeys},
        modifiers::reconcile,
    };
    use std::collections::HashSet;
    use winit::keyboard::ModifiersState;

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn reset_queue_and_modifiers() {
        KEY_MOD_BITS.store(0, Ordering::SeqCst);
        EXPLICIT_MOD_MASK.store(0, Ordering::SeqCst);
        let _ = take();
    }

    fn mods(shift: bool, ctrl: bool, alt: bool, super_key: bool) -> TouchInput {
        TouchInput::Modifiers {
            shift,
            ctrl,
            alt,
            super_key,
        }
    }

    fn key(code: KeyCode, state: ElementState) -> TouchInput {
        TouchInput::Key {
            code,
            state,
            text: None,
        }
    }

    #[test]
    fn a_touch_on_the_hotbar_finds_its_slot() {
        // 1920x1080 at GUI scale 4: the hotbar spans x 596..1324, y 992..1080.
        set_hotbar(Some(([1920, 1080], 4.0)));
        assert_eq!(hotbar_slot(600.0, 1000.0), Some(0));
        assert_eq!(hotbar_slot(1320.0, 1070.0), Some(8));
        assert_eq!(hotbar_slot(960.0, 1000.0), Some(4));
        assert_eq!(hotbar_slot(960.0, 900.0), None);
        assert_eq!(hotbar_slot(500.0, 1000.0), None);
        let m = HotbarMetrics::from_view([1920, 1080], 4.0, 3);
        assert_eq!(m.rect_px, [596.0, 992.0, 728.0, 88.0]);
        assert_eq!(m.selected_slot, 3);
        set_hotbar(None);
        assert_eq!(hotbar_slot(960.0, 1000.0), None);
    }

    #[test]
    fn inputs_come_out_once_in_order() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_queue_and_modifiers();
        push(TouchInput::Look { dx: 1.0, dy: 2.0 });
        push(TouchInput::Scroll { dx: 0.0, dy: -1.0 });
        push(TouchInput::TapWorld { x: 0.25, y: 0.75 });
        assert_eq!(
            take(),
            [
                TouchInput::Look { dx: 1.0, dy: 2.0 },
                TouchInput::Scroll { dx: 0.0, dy: -1.0 },
                TouchInput::TapWorld { x: 0.25, y: 0.75 },
            ]
        );
        assert!(take().is_empty());
    }

    #[test]
    fn modifier_key_press_and_release_ordering() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_queue_and_modifiers();

        // Press ShiftLeft (touch sneak / fly down): Modifiers BEFORE Key Pressed.
        push_key(KeyCode::ShiftLeft, true);
        assert_eq!(
            take(),
            [
                mods(true, false, false, false),
                key(KeyCode::ShiftLeft, ElementState::Pressed),
            ]
        );

        // Non-modifier keys emit only Key, never extra Modifiers.
        push_key(KeyCode::Space, true);
        push_key(KeyCode::Space, false);
        assert_eq!(
            take(),
            [
                key(KeyCode::Space, ElementState::Pressed),
                key(KeyCode::Space, ElementState::Released),
            ]
        );

        // Release ShiftLeft: Key Released BEFORE updated Modifiers.
        push_key(KeyCode::ShiftLeft, false);
        assert_eq!(
            take(),
            [
                key(KeyCode::ShiftLeft, ElementState::Released),
                mods(false, false, false, false),
            ]
        );

        // Press and release ControlLeft (touch sprint) with the same ordering.
        push_key(KeyCode::ControlLeft, true);
        push_key(KeyCode::ControlLeft, false);
        assert_eq!(
            take(),
            [
                mods(false, true, false, false),
                key(KeyCode::ControlLeft, ElementState::Pressed),
                key(KeyCode::ControlLeft, ElementState::Released),
                mods(false, false, false, false),
            ]
        );
    }

    #[test]
    fn overlapping_left_and_right_modifiers_keep_flag_until_both_released() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_queue_and_modifiers();

        push_key(KeyCode::ShiftLeft, true);
        push_key(KeyCode::ShiftRight, true);
        let _ = take();

        // Releasing Left Shift keeps shift=true while Right Shift is still down.
        push_key(KeyCode::ShiftLeft, false);
        assert_eq!(
            take(),
            [
                key(KeyCode::ShiftLeft, ElementState::Released),
                mods(true, false, false, false),
            ]
        );

        // Releasing Right Shift clears shift.
        push_key(KeyCode::ShiftRight, false);
        assert_eq!(
            take(),
            [
                key(KeyCode::ShiftRight, ElementState::Released),
                mods(false, false, false, false),
            ]
        );

        // Simultaneous Shift + Ctrl + Alt + Super combine cleanly.
        push_key(KeyCode::ShiftLeft, true);
        push_key(KeyCode::ControlRight, true);
        push_key(KeyCode::AltRight, true);
        push_key(KeyCode::SuperLeft, true);
        let _ = take();
        push_key(KeyCode::ControlRight, false);
        assert_eq!(
            take(),
            [
                key(KeyCode::ControlRight, ElementState::Released),
                mods(true, false, true, true),
            ]
        );
        reset_queue_and_modifiers();
    }

    #[test]
    fn explicit_modifiers_and_key_modifiers_stay_independent() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_queue_and_modifiers();

        // Sneaking via ShiftLeft while triggering hotbar stack-drop (explicit Ctrl -> 0):
        // clearing explicit modifiers must NOT wipe the held ShiftLeft modifier!
        push_key(KeyCode::ShiftLeft, true);
        let _ = take();
        push_explicit_modifiers(MOD_CTRL);
        push_key(KeyCode::KeyQ, true);
        push_key(KeyCode::KeyQ, false);
        push_explicit_modifiers(0);
        assert_eq!(
            take(),
            [
                mods(true, true, false, false),
                key(KeyCode::KeyQ, ElementState::Pressed),
                key(KeyCode::KeyQ, ElementState::Released),
                mods(true, false, false, false),
            ]
        );

        // Conversely, explicit Quick Move Shift survives a ShiftLeft key release.
        push_explicit_modifiers(MOD_SHIFT);
        let _ = take();
        push_key(KeyCode::ShiftLeft, false);
        assert_eq!(
            take(),
            [
                key(KeyCode::ShiftLeft, ElementState::Released),
                mods(true, false, false, false),
            ]
        );
        push_explicit_modifiers(0);
        assert_eq!(take(), [mods(false, false, false, false)]);
    }

    #[test]
    fn touch_shift_and_ctrl_survive_modifier_reconcile() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_queue_and_modifiers();

        let bindings = KeyBinds::default();
        let mut modifiers = ModifiersState::empty();
        let mut physical = HashSet::new();
        let mut toggles = ToggleKeys::default();

        let apply = |events: Vec<TouchInput>,
                     modifiers: &mut ModifiersState,
                     physical: &mut HashSet<KeyCode>,
                     toggles: &mut ToggleKeys| {
            for ev in events {
                match ev {
                    TouchInput::Modifiers {
                        shift,
                        ctrl,
                        alt,
                        super_key,
                    } => {
                        let mut state = ModifiersState::empty();
                        state.set(ModifiersState::SHIFT, shift);
                        state.set(ModifiersState::CONTROL, ctrl);
                        state.set(ModifiersState::ALT, alt);
                        state.set(ModifiersState::SUPER, super_key);
                        *modifiers = state;
                        reconcile(*modifiers, physical, &bindings, toggles, [false; 2], [false; 2]);
                    }
                    TouchInput::Key { code, state, .. } => {
                        let pressed = state == ElementState::Pressed;
                        if pressed {
                            physical.insert(code);
                        } else {
                            physical.remove(&code);
                        }
                        let slot = match code {
                            KeyCode::ShiftLeft => Some(SNEAK),
                            KeyCode::ControlLeft => Some(SPRINT),
                            _ => None,
                        };
                        if let Some(slot) = slot {
                            let action = if pressed {
                                KeyAction::Press
                            } else {
                                KeyAction::Release
                            };
                            toggles.key(slot, action, false, false);
                        }
                    }
                    _ => {}
                }
            }
        };

        push_key(KeyCode::ShiftLeft, true);
        push_key(KeyCode::ControlLeft, true);
        apply(take(), &mut modifiers, &mut physical, &mut toggles);

        // Next frame's heal_hold_latches checks modifiers.shift_key() / control_key():
        assert!(modifiers.shift_key());
        assert!(modifiers.control_key());
        assert!(physical.contains(&KeyCode::ShiftLeft));
        assert!(physical.contains(&KeyCode::ControlLeft));
        assert!(toggles.is_down(SNEAK));
        assert!(toggles.is_down(SPRINT));

        reconcile(modifiers, &mut physical, &bindings, &mut toggles, [false; 2], [false; 2]);
        assert!(toggles.is_down(SNEAK));
        assert!(toggles.is_down(SPRINT));

        push_key(KeyCode::ShiftLeft, false);
        push_key(KeyCode::ControlLeft, false);
        apply(take(), &mut modifiers, &mut physical, &mut toggles);
        assert!(!modifiers.shift_key());
        assert!(!modifiers.control_key());
        assert!(!toggles.is_down(SNEAK));
        assert!(!toggles.is_down(SPRINT));
    }

    #[test]
    fn touch_move_normalizes_and_clears_when_switching_away_from_touch() {
        set_active_input_mode(InputMode::Touch);
        // Magnitude > 1 is clamped onto the unit circle.
        set_touch_move(Some([3.0, 4.0]));
        let v = touch_move().expect("normalized move");
        assert!((v[0] - 0.6).abs() < 1e-5 && (v[1] - 0.8).abs() < 1e-5);
        // Non-finite or zero values clear movement.
        set_touch_move(Some([f32::NAN, 1.0]));
        assert_eq!(touch_move(), None);
        set_touch_move(Some([0.0, 1.0]));
        assert_eq!(touch_move(), Some([0.0, 1.0]));
        // Switching to Gamepad or KeyboardMouse automatically clears lingering touch movement.
        set_active_input_mode(InputMode::Gamepad);
        assert_eq!(active_input_mode(), InputMode::Gamepad);
        assert_eq!(touch_move(), None);
        set_active_input_mode(InputMode::KeyboardMouse);
        assert_eq!(active_input_mode(), InputMode::KeyboardMouse);
        set_active_input_mode(InputMode::Touch);
    }

    #[test]
    fn touch_facts_maps_verbs_and_targets_from_gameplay_guide() {
        let facts = Facts {
            flying: true,
            may_fly: true,
            target: Target::Entity {
                attackable: true,
                takes: Some(Verb::Trade),
            },
            item_use: Some(Verb::Eat),
            ..Facts::default()
        };
        let tf = TouchFacts::from_guide(&facts, false, true, true);
        assert!(tf.flying && tf.may_fly && tf.sprinting && tf.creative);
        assert_eq!(tf.attack_kind, AttackKind::Attack);
        // Target's verb (Trade) takes priority over held item's verb (Eat), as in vanilla.
        assert_eq!(tf.use_verb, UseVerb::Trade);
        assert!(tf.target_is_entity && !tf.target_is_block);

        // Busy hands (rowing a boat) disable both attack and use verbs.
        let busy = TouchFacts::from_guide(
            &Facts {
                hands_busy: true,
                riding: true,
                ..facts
            },
            false,
            false,
            false,
        );
        assert_eq!(busy.attack_kind, AttackKind::None);
        assert_eq!(busy.use_verb, UseVerb::None);
        assert!(busy.riding);
    }

    #[test]
    fn gamepad_snapshot_preserves_stick_peaks_until_consumed() {
        let mut s1 = IosGamepadSnapshot {
            connected: true,
            style: GlyphStyle::PlayStation,
            name: "DualSense".into(),
            peaks: [[0.9, 0.0], [0.0, -0.8]],
            ..Default::default()
        };
        set_ios_gamepad(s1.clone());
        // Stick returns to centre before the game polls: peak must survive!
        s1.peaks = [[0.0, 0.0], [0.0, 0.0]];
        set_ios_gamepad(s1);
        let got = take_ios_gamepad_snapshot().expect("snapshot");
        assert_eq!(got.style, GlyphStyle::PlayStation);
        assert_eq!(got.peaks, [[0.9, 0.0], [0.0, -0.8]]);
        // After taking, peaks reset to the live stick positions.
        let after = take_ios_gamepad_snapshot().expect("after");
        assert_eq!(after.peaks, [[0.0, 0.0], [0.0, 0.0]]);
    }

    #[test]
    fn rumble_and_feedback_queues_preserve_fifo_order() {
        while pop_rumble().is_some() {}
        while pop_feedback().is_some() {}
        let r = RumbleCommand {
            strong: 0.7,
            weak: 0.4,
            left_trigger: 0.2,
            right_trigger: 0.5,
            millis: 120,
        };
        push_rumble(r);
        assert_eq!(pop_rumble(), Some(r));
        assert_eq!(pop_rumble(), None);

        push_feedback(Feedback::BlockBroken);
        push_feedback(Feedback::ItemStackSplit);
        assert_eq!(pop_feedback(), Some(Feedback::BlockBroken));
        assert_eq!(pop_feedback(), Some(Feedback::ItemStackSplit));
        assert_eq!(pop_feedback(), None);
    }
}
