//! horizon-ios: input from the on-screen touch controls (HORIZON-IOS.md).
//!
//! The iOS host (`crates/horizon-ios`) draws Amethyst's touch controls over the game's view and
//! turns touches into keyboard and mouse input here, from the main thread. The game takes the
//! queue once per event-loop pass and feeds each entry through the same handlers as the
//! desktop's keyboard and mouse (`Game::take_touch_input`). On desktop nothing pushes, and the
//! queue stays empty.
use std::collections::VecDeque;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use winit::event::{ElementState, MouseButton};
use winit::keyboard::KeyCode;

/// One input from the touch controls.
#[derive(Clone, Debug, PartialEq)]
pub enum TouchInput {
    /// A key pressed or let go. `text` is what it types when pressed (a letter with Shift held
    /// is upper case), or `None` for keys that type nothing.
    Key {
        code: KeyCode,
        state: ElementState,
        text: Option<String>,
    },
    /// Text typed with no key (the on-screen keyboard's characters).
    Text(String),
    /// The pointer moved to this point of the view, in physical pixels.
    CursorTo { x: f64, y: f64 },
    /// A mouse button pressed or let go at the pointer.
    Button {
        button: MouseButton,
        state: ElementState,
    },
    /// The view turned, as a grabbed mouse moving by this many pixels.
    Look { dx: f64, dy: f64 },
    /// The wheel scrolled by lines (vanilla's hotbar scroll).
    Scroll { dx: f32, dy: f32 },
}

static QUEUE: Mutex<VecDeque<TouchInput>> = Mutex::new(VecDeque::new());
static GRABBING: AtomicBool = AtomicBool::new(false);
static WINDOW_CREATED: Mutex<Option<fn(&winit::window::Window)>> = Mutex::new(None);

/// Adds an input for the next event-loop pass.
pub fn push(input: TouchInput) {
    if let Ok(mut queue) = QUEUE.lock() {
        // A stalled game must not grow the queue without end.
        if queue.len() < 4096 {
            queue.push_back(input);
        }
    }
}

/// The inputs since the last call, oldest first.
pub fn take() -> Vec<TouchInput> {
    QUEUE
        .lock()
        .map(|mut queue| queue.drain(..).collect())
        .unwrap_or_default()
}

/// Whether the game holds the pointer (playing, no screen open): touches then turn the view
/// instead of moving a cursor, as in Amethyst's `isGrabbing`.
pub fn grabbing() -> bool {
    GRABBING.load(Ordering::Relaxed)
}

/// The game says whether it holds the pointer, once per event-loop pass.
pub fn set_grabbing(grabbing: bool) {
    GRABBING.store(grabbing, Ordering::Relaxed);
}

static HOTBAR: Mutex<Option<[f32; 3]>> = Mutex::new(None);

/// The game says where vanilla's hotbar is drawn, once per event-loop pass: the view's size in
/// physical pixels and the GUI scale, or `None` while no hotbar shows.
pub fn set_hotbar(view: Option<([u32; 2], f32)>) {
    if let Ok(mut slot) = HOTBAR.lock() {
        *slot = view.map(|([w, h], scale)| [w as f32, h as f32, scale]);
    }
}

/// The hotbar slot (0 to 8) under a point of the view in physical pixels (`Gui.renderHotbar`:
/// 182 by 22 GUI pixels, centred at the bottom, 20 per slot after a 1-pixel border).
pub fn hotbar_slot(x: f64, y: f64) -> Option<u8> {
    let [width, height, scale] = (*HOTBAR.lock().ok()?)?;
    if scale <= 0.0 {
        return None;
    }
    let (gx, gy) = (x as f32 / scale, y as f32 / scale);
    let left = (width / scale - 182.0) / 2.0;
    let top = height / scale - 22.0;
    if gy < top || gx < left || gx >= left + 182.0 {
        return None;
    }
    Some((((gx - left - 1.0) / 20.0).floor().clamp(0.0, 8.0)) as u8)
}

/// The host's hook for a newly created game window: the iOS host puts its touch controls over
/// the window's view there. Set it before the game starts.
pub fn on_window_created(hook: fn(&winit::window::Window)) {
    if let Ok(mut slot) = WINDOW_CREATED.lock() {
        *slot = Some(hook);
    }
}

/// The game created its window.
pub fn window_created(window: &winit::window::Window) {
    let hook = WINDOW_CREATED.lock().ok().and_then(|slot| *slot);
    if let Some(hook) = hook {
        hook(window);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_touch_on_the_hotbar_finds_its_slot() {
        // 1920x1080 at GUI scale 4: the hotbar spans x 596..1324, y 992..1080.
        set_hotbar(Some(([1920, 1080], 4.0)));
        assert_eq!(hotbar_slot(600.0, 1000.0), Some(0));
        assert_eq!(hotbar_slot(1320.0, 1070.0), Some(8));
        assert_eq!(hotbar_slot(960.0, 1000.0), Some(4));
        assert_eq!(hotbar_slot(960.0, 900.0), None);
        assert_eq!(hotbar_slot(500.0, 1000.0), None);
        set_hotbar(None);
        assert_eq!(hotbar_slot(960.0, 1000.0), None);
    }

    #[test]
    fn inputs_come_out_once_in_order() {
        let _ = take();
        push(TouchInput::Look { dx: 1.0, dy: 2.0 });
        push(TouchInput::Scroll { dx: 0.0, dy: -1.0 });
        assert_eq!(
            take(),
            [
                TouchInput::Look { dx: 1.0, dy: 2.0 },
                TouchInput::Scroll { dx: 0.0, dy: -1.0 }
            ]
        );
        assert!(take().is_empty());
    }
}
