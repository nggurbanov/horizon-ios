//! winit's `ApplicationHandler` for the game window: window and device events, shutting down,
//! and the idle step (`about_to_wait`).
use super::*;

impl Game<'_> {
    /// A run that a person's stray key, click or mouse move would spoil: a screenshot sequence, a
    /// `HORIZON_TICK_SCRIPT` scenario or a `record-replay`. While one runs, the keyboard, mouse
    /// and pad at this computer don't reach the game (`locks_out`, `poll_pads`), the window's
    /// focus stays as the run found it (`held_focus`) and its pointer grab stays inside the game
    /// (`internal_grab`).
    pub(super) fn scripted_run(&self) -> bool {
        self.screenshot_sequence.is_some() || self.tick_script.playing() || self.repro.replaying()
    }
}

/// A key, a modifier, a click, the wheel, the pointer or the input method. Resize and close are
/// not, so a person can still close the window. A modifier change counts: `reconcile` would
/// release a Shift or Ctrl the run holds.
fn is_input(event: &WindowEvent) -> bool {
    matches!(
        event,
        WindowEvent::KeyboardInput { .. }
            | WindowEvent::ModifiersChanged(_)
            | WindowEvent::MouseInput { .. }
            | WindowEvent::MouseWheel { .. }
            | WindowEvent::CursorMoved { .. }
            | WindowEvent::Ime(_)
    )
}

/// A person's input during a scripted run is dropped. What the run itself sends (the control
/// socket, a replay, the game's own) still plays.
fn locks_out(origin: input_trace::InputOrigin, scripted: bool, event: &WindowEvent) -> bool {
    scripted && origin == input_trace::InputOrigin::User && is_input(event)
}

/// A person clicking into the window or away from it during a scripted run. A replay's look and
/// clicks act by the focus and the pointer grab, which that would change mid-run: the run keeps
/// the focus it started with, and the last change applies once it ends (`settle_after_run`).
fn held_focus(
    origin: input_trace::InputOrigin,
    scripted: bool,
    event: &WindowEvent,
) -> Option<bool> {
    match event {
        WindowEvent::Focused(focused) if scripted && origin == input_trace::InputOrigin::User => {
            Some(*focused)
        }
        _ => None,
    }
}

/// What a person's event does at an agent's window no one has clicked yet.
#[derive(Debug, PartialEq)]
enum Unclaimed {
    /// A mouse button pressed inside it: the window is theirs from this press on.
    Claims,
    /// Their keys, wheel, input method and button releases, and the focus the system gives the
    /// window or takes from it: the game the agent drives hears none of them.
    Dropped,
    /// Everything else, and whatever the agent or the game sends.
    Passes,
}

/// Only a press claims the window. The focus doesn't: Windows and X11 can hand it to a window
/// nobody clicked, and the person's keys and mouse would then steer the agent's game (#15449).
/// The pointer's position still passes, so the press that claims a menu lands where it points.
fn at_unclaimed(
    origin: input_trace::InputOrigin,
    unclaimed: bool,
    event: &WindowEvent,
) -> Unclaimed {
    if !unclaimed || origin != input_trace::InputOrigin::User {
        return Unclaimed::Passes;
    }
    match event {
        WindowEvent::MouseInput {
            state: ElementState::Pressed,
            ..
        } => Unclaimed::Claims,
        WindowEvent::CursorMoved { .. } => Unclaimed::Passes,
        WindowEvent::Focused(_) => Unclaimed::Dropped,
        _ if is_input(event) => Unclaimed::Dropped,
        _ => Unclaimed::Passes,
    }
}

/// The Shift, Ctrl or Alt a person holds at an agent's window no one has clicked yet. The game
/// doesn't hear of them, but winit tells of modifiers only as they change: the last state is
/// kept for the claim, where a Ctrl held since before the click would otherwise read as up.
fn held_modifiers(
    origin: input_trace::InputOrigin,
    unclaimed: bool,
    event: &WindowEvent,
) -> Option<winit::event::Modifiers> {
    match event {
        WindowEvent::ModifiersChanged(modifiers)
            if unclaimed && origin == input_trace::InputOrigin::User =>
        {
            Some(*modifiers)
        }
        _ => None,
    }
}

impl Game<'_> {
    /// winit's `window_event`. The control socket and the pad menu call it too, with the
    /// input they make up.
    pub(super) fn handle_window_event(
        &mut self,
        event_loop: &dyn EventLoopCtl,
        id: WindowId,
        event: WindowEvent,
        origin: input_trace::InputOrigin,
    ) {
        let input = matches!(
            event,
            WindowEvent::KeyboardInput { .. }
                | WindowEvent::MouseInput { .. }
                | WindowEvent::MouseWheel { .. }
                | WindowEvent::Ime(_)
        );
        self.with_user_input(input, |game| {
            game.handle_window_event_as(event_loop, id, event, origin);
        });
    }

    pub(super) fn handle_window_event_as(
        &mut self,
        event_loop: &dyn EventLoopCtl,
        id: WindowId,
        mut event: WindowEvent,
        origin: input_trace::InputOrigin,
    ) {
        // A headless game has no window: its events (the frame, the control socket's input)
        // carry `WindowId::dummy()`.
        let ours = match &self.window {
            Some(w) => w.id() == id,
            None => self.options.headless,
        };
        if !ours {
            return;
        }
        if let Some(modifiers) = held_modifiers(origin, self.unclaimed_window, &event) {
            self.unclaimed_modifiers = Some(modifiers);
        }
        if locks_out(origin, self.scripted_run(), &event) {
            return;
        }
        if let Some(focused) = held_focus(origin, self.scripted_run(), &event) {
            self.focus_after_run = Some(focused);
            return;
        }
        match at_unclaimed(origin, self.unclaimed_window, &event) {
            Unclaimed::Claims => self.claim_window(event_loop),
            Unclaimed::Dropped => return,
            Unclaimed::Passes => {}
        }
        follow_keymap(&mut event);
        // MacosUtil.setCtrlClickEmulatesRightClick: Control + left click is a right click.
        if let WindowEvent::MouseInput { state, button, .. } = &mut event
            && *button == MouseButton::Left
            && self.right_click_emulation.is_right_click(
                *state == ElementState::Pressed,
                self.modifiers.control_key(),
                cfg!(target_os = "macos") && self.settings.ctrl_click_emulates_right_click,
            )
        {
            *button = MouseButton::Right;
        }
        // Who caused it, before the event is handled: the trace wants the
        // window's own keys, never the ones the socket made up.
        self.trace_window_event(origin, &event);
        if let WindowEvent::KeyboardInput { event, .. } = &event
            && let PhysicalKey::Code(key) = event.physical_key
        {
            if event.state == ElementState::Pressed {
                self.physical_keys.insert(key);
                horizon_client::keybinds::learn_layout(event);
            } else {
                self.physical_keys.remove(&key);
            }
        }
        if matches!(
            &event,
            WindowEvent::MouseInput {
                state: ElementState::Pressed,
                ..
            }
        ) && !self.input_made_pointer_event()
        {
            self.pad.keyboard_took_over = true;
        }
        if let WindowEvent::MouseInput { state, button, .. } = &event {
            if *state == ElementState::Pressed {
                self.physical_buttons.insert(*button);
            } else {
                self.physical_buttons.remove(button);
            }
        }
        let mouse = if !self.pad_synthetic_input()
            && let WindowEvent::MouseInput { state, button, .. } = &event
        {
            Some((
                glfw_button(*button),
                *state == ElementState::Pressed,
                glfw_modifiers(self.modifiers),
            ))
        } else {
            None
        };
        if let Some((button, pressed, modifiers)) = mouse {
            let mut canceled = false;
            self.native_mouse_button_pre(button, pressed, modifiers, &mut canceled);
            if canceled {
                return;
            }
        }
        if mouse.is_some()
            && let WindowEvent::MouseInput { state, button, .. } = &event
        {
            self.mod_mappings_button(*button, *state == ElementState::Pressed);
        }
        let resized = matches!(event, WindowEvent::Resized(_));
        self.handle_window_event_inner(event_loop, event);
        if resized {
            self.notify_window_resize();
        }
        // A title screen the event asked for opens before the next event.
        self.settle_title_mode();
        if let Some((button, pressed, modifiers)) = mouse {
            self.native_mouse_button_post(button, pressed, modifiers);
        }
    }

    /// The loop ended: close the pads' output, save the world.
    pub(super) fn shut_down(&mut self) {
        if self.error.is_none()
            && let Some(renderer) = &mut self.renderer
        {
            renderer.drop_hdr_marker();
        }
        self.end_screenshot_sequence(Err("cancelled: the game is closing".into()));
        self.pad_close_output();
        if let Err(e) = self.save_for_exit() {
            log::warn!("Horizon: failed to save the world on exit: {e}");
        }
        self.finish_profile();
        // The client's last moment: its world is left and saved, its options and
        // resources are still held. A dedicated server and a splitscreen guest skip
        // it, as `client_setup` does.
        if self.options.is_client_start() {
            self.native_client_stopping();
        }
    }

    /// winit's `about_to_wait`: what happens between frames (stop requests, the closing
    /// save, world entry, the control socket, pads), then the next frame.
    pub(super) fn idle(&mut self, event_loop: &dyn EventLoopCtl) {
        // A splitscreen player's game has nothing to save: P1's shuts the process down.
        if horizon_threads::stop_requests() > 0
            && !self.options.split_guest
            && self.pending_save.as_ref().is_none_or(|save| !save.quit)
        {
            // SIGTERM, SIGINT or SIGHUP: the shutdown hook's server halt, as a window close.
            if let Err(error) = self.begin_closing_save(true) {
                self.error = Some(error);
                event_loop.exit();
                return;
            }
        }
        if self.pending_save.is_some() {
            match self.poll_closing_save() {
                Ok(true) => event_loop.exit(),
                Ok(false) => {
                    if let Some(window) = &self.window {
                        window.request_redraw();
                    }
                    // Yield between polls even when disk I/O is slow.
                    event_loop.set_control_flow(ControlFlow::WaitUntil(
                        Instant::now() + Duration::from_millis(4),
                    ));
                }
                Err(error) => {
                    self.error = Some(error);
                    self.exit_on_error(event_loop);
                }
            }
            return;
        }
        if let Err(error) = horizon_client::spans::time("world_entry", || self.resume_world_entry())
        {
            self.error = Some(error);
            self.exit_on_error(event_loop);
            return;
        }
        // The world a backup made before its upgrade opens (EditWorldScreen's callback).
        if let Some(folder) = self.title.as_mut().and_then(|t| t.take_open_request())
            && let Err(error) = self.open_world(&folder, None, None, false, None)
        {
            self.error = Some(error);
            event_loop.exit();
            return;
        }
        // A Realm's address came back (GetServerDetailsTask hands over to ConnectScreen).
        if let Some(action) = self.title.as_mut().and_then(|t| t.take_connect_request())
            && let Err(error) = self.title_action(event_loop, action)
        {
            self.error = Some(error);
            event_loop.exit();
            return;
        }
        horizon_client::spans::time("server_packs", || self.tick_server_packs());
        horizon_client::spans::time("control", || self.poll_control(event_loop));
        if self.pending_save.is_some() {
            return;
        }
        horizon_client::spans::time("pads", || self.poll_pads(event_loop));
        self.settle_after_run(event_loop);
        self.pause_if_inactive();
        if let Some(limit) = self.options.time_limit()
            && self.started.elapsed() > limit
        {
            self.error = Some(format!("run timed out after {} s", limit.as_secs()).into());
            event_loop.exit();
            return;
        }
        if let Some(w) = &self.window {
            if self.options.offscreen {
                // Offscreen frames don't wait for the window to be drawn: an
                // occluded window (a locked macOS session) gets no redraws.
                let id = w.id();
                self.handle_window_event(
                    event_loop,
                    id,
                    WindowEvent::RedrawRequested,
                    input_trace::InputOrigin::Game,
                );
            } else {
                w.request_redraw();
            }
        } else if self.options.headless {
            // The headless loop paces the frames itself (`run_headless`).
            self.handle_window_event(
                event_loop,
                WindowId::dummy(),
                WindowEvent::RedrawRequested,
                input_trace::InputOrigin::Game,
            );
            return;
        }
        // Consume the last frame's result: a hidden compositor may stop sending
        // redraws altogether, leaving a successful result stale indefinitely.
        event_loop.set_control_flow(event_loop::redraw_flow(
            &mut self.frame_drawn,
            self.options.offscreen,
            Instant::now(),
        ));
    }
}

/// horizon-ios: an iOS overlay, keyboard, or mouse input translated into game events.
#[cfg(target_os = "ios")]
pub(super) enum TouchEvent {
    Window(WindowEvent),
    Device(DeviceEvent),
    Modifiers(winit::keyboard::ModifiersState),
    SetChatText(String),
    TapWorld { x: f32, y: f32 },
    HoldWorld { x: f32, y: f32, active: bool },
    MoveWorldHold { x: f32, y: f32 },
}

/// horizon-ios: the touch/keyboard/mouse bridge input since the last pass (`touch_bridge`), as
/// the events Horizon's window, device, chat, and Tap-to-Interact handlers consume.
#[cfg(target_os = "ios")]
pub(super) fn touch_events() -> Vec<TouchEvent> {
    use horizon_client_input::touch_bridge::{self, TouchInput};
    use winit::event::{KeyEvent, MouseScrollDelta, TouchPhase};
    use winit::keyboard::{Key, KeyLocation, ModifiersState, NativeKey, NativeKeyCode};
    let device_id = DeviceId::dummy();
    let key = |event: KeyEvent| {
        TouchEvent::Window(WindowEvent::KeyboardInput {
            device_id,
            event,
            is_synthetic: false,
        })
    };
    let mut events = Vec::new();
    for input in touch_bridge::take() {
        match input {
            TouchInput::Key { code, state, text } => {
                let logical = named_key(code).map(Key::Named).unwrap_or_else(|| {
                    text.as_deref().map_or(
                        Key::Unidentified(NativeKey::Unidentified),
                        |t| Key::Character(t.into()),
                    )
                });
                let text = text.filter(|_| state == ElementState::Pressed);
                events.push(key(KeyEvent::synthetic(
                    PhysicalKey::Code(code),
                    logical,
                    text.map(Into::into),
                    KeyLocation::Standard,
                    state,
                    false,
                )));
            }
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
                events.push(TouchEvent::Modifiers(state));
            }
            TouchInput::Text(text) => {
                for state in [ElementState::Pressed, ElementState::Released] {
                    events.push(key(KeyEvent::synthetic(
                        PhysicalKey::Unidentified(NativeKeyCode::Unidentified),
                        Key::Character(text.as_str().into()),
                        (state == ElementState::Pressed).then(|| text.as_str().into()),
                        KeyLocation::Standard,
                        state,
                        false,
                    )));
                }
            }
            TouchInput::SetChatText(text) => events.push(TouchEvent::SetChatText(text)),
            TouchInput::CursorTo { x, y } => {
                events.push(TouchEvent::Window(WindowEvent::CursorMoved {
                    device_id,
                    position: winit::dpi::PhysicalPosition::new(x, y),
                }))
            }
            TouchInput::Button { button, state } => {
                events.push(TouchEvent::Window(WindowEvent::MouseInput {
                    device_id,
                    state,
                    button,
                }))
            }
            TouchInput::Look { dx, dy } => {
                events.push(TouchEvent::Device(DeviceEvent::MouseMotion {
                    delta: (dx, dy),
                }))
            }
            TouchInput::Scroll { dx, dy } => {
                events.push(TouchEvent::Window(WindowEvent::MouseWheel {
                    device_id,
                    delta: MouseScrollDelta::LineDelta(dx, dy),
                    phase: TouchPhase::Moved,
                }))
            }
            TouchInput::TapWorld { x, y } => events.push(TouchEvent::TapWorld { x, y }),
            TouchInput::HoldWorld { x, y, active } => {
                events.push(TouchEvent::HoldWorld { x, y, active })
            }
            TouchInput::MoveWorldHold { x, y } => events.push(TouchEvent::MoveWorldHold { x, y }),
        }
    }
    events
}

#[cfg(target_os = "ios")]
impl Game<'_> {
    fn ios_screen_kind(&self, playing: bool) -> horizon_client_input::touch_bridge::ScreenKind {
        use horizon_client_input::touch_bridge::ScreenKind;
        if self.title.is_some()
            || self.dialog_open()
            || self.sign_edit.is_some()
            || self.book.is_some()
            || self.link_prompt.is_some()
            || self.command_prompt.is_some()
            || self.code_of_conduct.is_some()
        {
            return ScreenKind::Menu;
        }
        if playing {
            return ScreenKind::Playing;
        }
        match self.screen {
            Screen::Playing => ScreenKind::Menu,
            Screen::Chat => ScreenKind::Chat,
            Screen::Creative => ScreenKind::Creative,
            Screen::Inventory => {
                if self.container.is_some() || self.station.is_some() {
                    ScreenKind::Container
                } else {
                    ScreenKind::Inventory
                }
            }
            _ => ScreenKind::Menu,
        }
    }

    fn take_touch_input(&mut self, event_loop: &ActiveEventLoop) {
        use horizon_client::actions::Action;
        use horizon_client_input::touch_bridge::{
            self, HotbarMetrics, InputMode, OverlayState, TouchFacts,
        };
        let playing = self.captured
            && self.screen == Screen::Playing
            && self.title.is_none()
            && !self.dialog_open()
            && self.sign_edit.is_none()
            && self.book.is_none();
        if !playing {
            self.touch_state.aim = None;
            self.touch_state.hold_uses_item = false;
        }
        let screen_kind = self.ios_screen_kind(playing);
        let text_field_focused = self.text_field_focused();
        let chat_open = self.screen == Screen::Chat && self.title.is_none();
        let live_chat = self
            .ui
            .chat_screen
            .as_ref()
            .filter(|_| chat_open)
            .map(|s| s.value())
            .unwrap_or("");
        if live_chat != self.touch_state.chat_text {
            self.touch_state.chat_text = live_chat.to_owned();
            self.touch_state.chat_revision = self.touch_state.chat_revision.wrapping_add(1);
        }
        let guide_facts = if playing && self.player.is_some() {
            self.cached_guide_facts()
        } else {
            Default::default()
        };
        let sneaking = self.keys.held(Action::Sneak);
        let sprinting = self.player.as_ref().is_some_and(|p| p.sprinting);
        let facts = TouchFacts::from_guide(&guide_facts, sneaking, sprinting, self.creative);
        let (gui_scale, hotbar) = self.renderer.as_ref().map_or((1.0, None), |r| {
            let size = [r.config.width, r.config.height];
            let scale = HudBatch::new(size, self.settings.gui_scale_inputs()).scale;
            let metrics = (playing && !self.spectator() && !self.ui.hide_gui)
                .then(|| HotbarMetrics::from_view(size, scale, self.selected as u8));
            (scale, metrics)
        });
        let mining_progress = self
            .mining
            .as_ref()
            .map_or(0.0, |m| m.progress.clamp(0.0, 1.0));
        touch_bridge::set_overlay_state(OverlayState {
            grabbing: playing,
            screen_kind,
            text_field_focused,
            chat_open,
            chat_text: self.touch_state.chat_text.clone(),
            chat_revision: self.touch_state.chat_revision,
            hotbar,
            facts,
            mining_progress,
            carrying_item: self.carried.is_some(),
            gui_scale,
        });
        // Keep console mode cleanly yielded whenever Touch or Keyboard+Mouse owns input.
        if touch_bridge::active_input_mode() != InputMode::Gamepad && self.pad.in_use {
            self.pad_yield_input(event_loop);
            self.pad.keyboard_took_over = true;
        }
        let Some(id) = self.window.as_ref().map(|w| w.id()) else {
            return;
        };
        for event in touch_events() {
            match event {
                TouchEvent::Window(event) => self.window_event(event_loop, id, event),
                TouchEvent::Device(event) => {
                    self.device_event(event_loop, DeviceId::dummy(), event)
                }
                TouchEvent::Modifiers(state) => self.update_modifiers(state),
                TouchEvent::SetChatText(text) => self.ios_set_chat_text(&text),
                TouchEvent::TapWorld { x, y } => {
                    if self.captured
                        && self.screen == Screen::Playing
                        && self.title.is_none()
                        && !self.dialog_open()
                    {
                        self.touch_state.aim = Some(super::TouchAim {
                            point: [x, y],
                            hold: false,
                            expire_after_tick: self.ticks,
                        });
                        self.tick_hit.set(None);
                        self.tick_mob = None;
                        let tap_facts = self.pad_guide_facts();
                        let button = super::classify_world_tap(&tap_facts);
                        for state in [ElementState::Pressed, ElementState::Released] {
                            self.window_event(
                                event_loop,
                                id,
                                WindowEvent::MouseInput {
                                    device_id: DeviceId::dummy(),
                                    state,
                                    button,
                                },
                            );
                        }
                    }
                }
                TouchEvent::HoldWorld { x, y, active } => {
                    if active {
                        if self.captured
                            && self.screen == Screen::Playing
                            && self.title.is_none()
                            && !self.dialog_open()
                        {
                            self.touch_state.aim = Some(super::TouchAim {
                                point: [x, y],
                                hold: true,
                                expire_after_tick: self.ticks,
                            });
                            self.tick_hit.set(None);
                            self.tick_mob = None;
                            let hold_facts = self.pad_guide_facts();
                            let button = super::classify_world_hold(&hold_facts);
                            self.touch_state.hold_uses_item = button == MouseButton::Right;
                            self.window_event(
                                event_loop,
                                id,
                                WindowEvent::MouseInput {
                                    device_id: DeviceId::dummy(),
                                    state: ElementState::Pressed,
                                    button,
                                },
                            );
                        }
                    } else {
                        let button = if self.touch_state.hold_uses_item {
                            MouseButton::Right
                        } else {
                            MouseButton::Left
                        };
                        self.touch_state.hold_uses_item = false;
                        self.window_event(
                            event_loop,
                            id,
                            WindowEvent::MouseInput {
                                device_id: DeviceId::dummy(),
                                state: ElementState::Released,
                                button,
                            },
                        );
                        self.touch_state.aim = None;
                    }
                }
                TouchEvent::MoveWorldHold { x, y } => {
                    if let Some(ta) = self.touch_state.aim.as_mut()
                        && ta.hold
                    {
                        ta.point = [x, y];
                    }
                }
            }
        }
    }
}

/// The logical key a touch control's key code stands for, where it isn't a character.
#[cfg(target_os = "ios")]
fn named_key(code: KeyCode) -> Option<winit::keyboard::NamedKey> {
    use winit::keyboard::NamedKey as N;
    Some(match code {
        KeyCode::Escape => N::Escape,
        KeyCode::Enter | KeyCode::NumpadEnter => N::Enter,
        KeyCode::Backspace => N::Backspace,
        KeyCode::Tab => N::Tab,
        KeyCode::Space => N::Space,
        KeyCode::ShiftLeft | KeyCode::ShiftRight => N::Shift,
        KeyCode::ControlLeft | KeyCode::ControlRight => N::Control,
        KeyCode::AltLeft | KeyCode::AltRight => N::Alt,
        KeyCode::SuperLeft | KeyCode::SuperRight => N::Super,
        KeyCode::ArrowUp => N::ArrowUp,
        KeyCode::ArrowDown => N::ArrowDown,
        KeyCode::ArrowLeft => N::ArrowLeft,
        KeyCode::ArrowRight => N::ArrowRight,
        KeyCode::Delete => N::Delete,
        KeyCode::Home => N::Home,
        KeyCode::End => N::End,
        KeyCode::PageUp => N::PageUp,
        KeyCode::PageDown => N::PageDown,
        KeyCode::F1 => N::F1,
        KeyCode::F2 => N::F2,
        KeyCode::F3 => N::F3,
        KeyCode::F4 => N::F4,
        KeyCode::F5 => N::F5,
        KeyCode::F6 => N::F6,
        KeyCode::F7 => N::F7,
        KeyCode::F8 => N::F8,
        KeyCode::F9 => N::F9,
        KeyCode::F10 => N::F10,
        KeyCode::F11 => N::F11,
        KeyCode::F12 => N::F12,
        _ => return None,
    })
}

impl ApplicationHandler for Game<'_> {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }
        debug_keys::warm_debug_cpu();
        // The Window constructor: created fullscreen when options.txt or --fullscreen says so.
        let fullscreen = self.settings.fullscreen || self.options.fullscreen;
        let size = self.options.window_size.map(f64::from);
        self.fullscreen = horizon_client::window::FullscreenState::new(fullscreen);
        let attributes =
            horizon_client::window::with_icon(Window::default_attributes().with_title("Horizon"));
        // Wayland names the window by its app id, which the horizon.desktop entry matches.
        #[cfg(target_os = "linux")]
        let attributes = winit::platform::wayland::WindowAttributesExtWayland::with_name(
            attributes, "horizon", "horizon",
        );
        // A game an agent started opens without the focus, as splitscreen's windows do, and
        // the person keeps their keyboard and pointer until they click it (`unclaimed_window`).
        // X11 activates it anyway, and Windows can too: the focus claims nothing.
        let agent_started = self.options.control.is_some();
        self.unclaimed_window = agent_started && !self.options.offscreen;
        // `--offscreen` renders into a texture: its window would only show white.
        let window_step = startup::step("window.create");
        let window = match event_loop.create_window(
            attributes
                .with_inner_size(winit::dpi::LogicalSize::new(size[0], size[1]))
                .with_fullscreen(fullscreen.then_some(winit::window::Fullscreen::Borderless(None)))
                .with_visible(!self.options.offscreen)
                .with_active(!agent_started),
        ) {
            Ok(w) => Arc::new(w),
            Err(e) => {
                self.error = Some(e.into());
                event_loop.exit();
                return;
            }
        };
        horizon_client::window::settle_created_fullscreen(&window, fullscreen);
        #[cfg(target_os = "windows")]
        if let Some(hwnd) = hwnd(&window) {
            horizon_threads::system_menu::suppress(hwnd);
        }
        drop(window_step);
        match self.new_renderer(window.clone()) {
            Ok(r) => {
                self.renderer = Some(r);
                self.world_renderer_ready = true;
            }
            Err(e) => {
                self.error = Some(e);
                event_loop.exit();
                return;
            }
        }
        self.resize_state = Some(self.resize_state_of(window.inner_size()));
        // horizon-ios: the host puts its touch controls over the new window's view.
        horizon_client_input::touch_bridge::window_created(&window);
        self.window = Some(window);
        self.ime_allowed = false;
        self.ime_area = None;
        self.apply_settings();
        self.previous = Instant::now();
    }
    fn window_event(&mut self, event_loop: &ActiveEventLoop, id: WindowId, event: WindowEvent) {
        let key = if self.window.as_ref().is_some_and(|w| w.id() == id)
            && !self.scripted_run()
            && !self.unclaimed_window
            && let WindowEvent::KeyboardInput {
                event,
                is_synthetic: false,
                ..
            } = &event
        {
            Some((event.clone(), glfw_modifiers(self.modifiers)))
        } else {
            None
        };
        self.handle_window_event(event_loop, id, event, input_trace::InputOrigin::User);
        if let Some((event, modifiers)) = key {
            use winit::platform::modifier_supplement::KeyEventExtModifierSupplement;
            let name = match event.physical_key {
                PhysicalKey::Code(code) => horizon_client::keybinds::key_name(code),
                PhysicalKey::Unidentified(_) => None,
            };
            let layout_key = horizon_client::keybinds::layout_key_name(
                event.physical_key,
                &event.key_without_modifiers(),
            );
            let raw_code = horizon_client::keybinds::raw_key_code(event.physical_key);
            let action = match (event.state, event.repeat) {
                (winit::event::ElementState::Released, _) => mod_api::KeyAction::Release,
                (_, false) => mod_api::KeyAction::Press,
                (_, true) => mod_api::KeyAction::Repeat,
            };
            // Still the key's handling: a mod's key hook may reach the clipboard.
            self.with_user_input(true, |game| {
                game.key_input(name, layout_key, raw_code, action, modifiers);
            });
        }
    }
    fn device_event(&mut self, event_loop: &ActiveEventLoop, _: DeviceId, event: DeviceEvent) {
        // A composited view renders offscreen but its keyboard/mouse owner still
        // controls a visible native window. A headless offscreen run never does.
        if self.pending_save.is_none()
            && !self.scripted_run()
            && !self.unclaimed_window
            && self.captured
            && self.focused
            && self.keyboard_mouse
            && (!self.options.offscreen || self.split_window)
            && self.screen == Screen::Playing
            && let DeviceEvent::MouseMotion { delta: (x, y) } = event
        {
            if self.pad_radial_captures() {
                return;
            }
            if x != 0.0 || y != 0.0 {
                self.pad_yield_input(event_loop);
            }
            // MouseHandler.onMove with the pointer grabbed; applied once per frame.
            self.note_input(
                input_trace::InputOrigin::User,
                input_trace::TraceKind::Motion { x, y },
            );
            self.mouse.on_move(0.0, 0.0, x, y, true, true);
            self.last_input = Instant::now();
        }
    }
    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        #[cfg(target_os = "ios")]
        self.take_touch_input(event_loop);
        // Every event-loop pass, drawn or not: a window that stops redrawing (a lost
        // device, an occluded window) must still end after a server crash.
        self.exit_after_server_crash();
        self.idle(event_loop);
    }
    /// The application is ending. On macOS, Quit (Cmd+Q) ends it through
    /// applicationWillTerminate without a CloseRequested; vanilla's GLFW
    /// window turns it into a window close, so Minecraft.stop saves the world.
    fn exiting(&mut self, _event_loop: &ActiveEventLoop) {
        self.shut_down();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use input_trace::InputOrigin;
    use winit::dpi::{PhysicalPosition, PhysicalSize};
    use winit::event::{Ime, Modifiers, TouchPhase};
    use winit::keyboard::ModifiersState;

    // A key's `KeyEvent` can't be made outside winit; these are the person's other inputs.
    fn inputs() -> Vec<WindowEvent> {
        let device_id = DeviceId::dummy();
        vec![
            WindowEvent::MouseInput {
                device_id,
                state: ElementState::Pressed,
                button: MouseButton::Left,
            },
            WindowEvent::MouseWheel {
                device_id,
                delta: MouseScrollDelta::LineDelta(0.0, 1.0),
                phase: TouchPhase::Moved,
            },
            WindowEvent::CursorMoved {
                device_id,
                position: PhysicalPosition::new(10.0, 20.0),
            },
            WindowEvent::ModifiersChanged(Modifiers::from(ModifiersState::empty())),
            WindowEvent::Ime(Ime::Commit("a".into())),
        ]
    }

    #[test]
    fn a_person_is_locked_out_of_a_scripted_run_only() {
        for event in inputs() {
            assert!(locks_out(InputOrigin::User, true, &event), "{event:?}");
            assert!(!locks_out(InputOrigin::User, false, &event), "{event:?}");
        }
    }

    #[test]
    fn what_the_run_sends_still_plays() {
        for event in inputs() {
            assert!(!locks_out(InputOrigin::Agent, true, &event), "{event:?}");
            assert!(!locks_out(InputOrigin::Game, true, &event), "{event:?}");
        }
    }

    #[test]
    fn a_person_can_still_close_the_window() {
        for event in [
            WindowEvent::CloseRequested,
            WindowEvent::Resized(PhysicalSize::new(854, 480)),
        ] {
            assert!(!locks_out(InputOrigin::User, true, &event), "{event:?}");
            assert_eq!(
                held_focus(InputOrigin::User, true, &event),
                None,
                "{event:?}"
            );
        }
    }

    #[test]
    fn only_a_persons_press_claims_an_agents_window() {
        let device_id = DeviceId::dummy();
        let press = WindowEvent::MouseInput {
            device_id,
            state: ElementState::Pressed,
            button: MouseButton::Left,
        };
        assert_eq!(
            at_unclaimed(InputOrigin::User, true, &press),
            Unclaimed::Claims
        );
        // The focus alone claims nothing, and the game doesn't hear of it.
        for focused in [true, false] {
            let event = WindowEvent::Focused(focused);
            assert_eq!(
                at_unclaimed(InputOrigin::User, true, &event),
                Unclaimed::Dropped
            );
        }
        let release = WindowEvent::MouseInput {
            device_id,
            state: ElementState::Released,
            button: MouseButton::Left,
        };
        for event in inputs().into_iter().skip(1).chain([release]) {
            let want = match event {
                WindowEvent::CursorMoved { .. } => Unclaimed::Passes,
                _ => Unclaimed::Dropped,
            };
            assert_eq!(
                at_unclaimed(InputOrigin::User, true, &event),
                want,
                "{event:?}"
            );
        }
        for event in [
            WindowEvent::CloseRequested,
            WindowEvent::Resized(PhysicalSize::new(854, 480)),
        ] {
            assert_eq!(
                at_unclaimed(InputOrigin::User, true, &event),
                Unclaimed::Passes,
                "{event:?}"
            );
        }
    }

    #[test]
    fn a_persons_modifiers_are_kept_for_the_claim() {
        let shift = Modifiers::from(ModifiersState::SHIFT);
        let event = WindowEvent::ModifiersChanged(shift);
        assert_eq!(held_modifiers(InputOrigin::User, true, &event), Some(shift));
        assert_eq!(held_modifiers(InputOrigin::User, false, &event), None);
        assert_eq!(held_modifiers(InputOrigin::Agent, true, &event), None);
        assert_eq!(
            held_modifiers(InputOrigin::User, true, &WindowEvent::Focused(true)),
            None
        );
    }

    #[test]
    fn the_agent_still_drives_its_unclaimed_window() {
        let events = inputs().into_iter().chain([WindowEvent::Focused(true)]);
        for event in events {
            for origin in [InputOrigin::Agent, InputOrigin::Game] {
                assert_eq!(
                    at_unclaimed(origin, true, &event),
                    Unclaimed::Passes,
                    "{event:?}"
                );
            }
        }
    }

    #[test]
    fn an_ordinary_window_hears_everything() {
        let events = inputs().into_iter().chain([WindowEvent::Focused(true)]);
        for event in events {
            assert_eq!(
                at_unclaimed(InputOrigin::User, false, &event),
                Unclaimed::Passes,
                "{event:?}"
            );
        }
    }

    #[test]
    fn a_persons_focus_change_waits_for_the_run_to_end() {
        for focused in [true, false] {
            let event = WindowEvent::Focused(focused);
            assert_eq!(held_focus(InputOrigin::User, true, &event), Some(focused));
            assert_eq!(held_focus(InputOrigin::User, false, &event), None);
            assert!(!locks_out(InputOrigin::User, true, &event));
        }
    }

    #[test]
    fn screen_ray_direction_matches_camera_projection_round_trip() {
        let eye = [12.5, 65.62, -4.25];
        for (yaw, pitch, fov, aspect) in [
            (0.0_f32, 0.0_f32, 70.0_f32, 16.0 / 9.0),
            (45.0, -25.0, 90.0, 2556.0 / 1179.0),
            (-135.0, 40.0, 60.0, 4.0 / 3.0),
        ] {
            let proj = glam::Mat4::perspective_rh(fov.to_radians(), aspect, 256.0, 0.05)
                .to_cols_array();
            for point in [[0.5_f32, 0.5], [0.2, 0.3], [0.85, 0.75], [0.1, 0.9]] {
                let dir = super::super::screen_ray_direction(yaw, pitch, fov, aspect, point);
                let len = (dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]).sqrt();
                assert!((len - 1.0).abs() < 1e-6);
                let world_pt = [eye[0] + dir[0] * 4.0, eye[1] + dir[1] * 4.0, eye[2] + dir[2] * 4.0];
                let ndc = horizon_client::camera::project_point(&proj, eye, yaw, pitch, world_pt)
                    .expect("projected screen point");
                let want_x = point[0] * 2.0 - 1.0;
                let want_y = 1.0 - point[1] * 2.0;
                assert!(
                    (ndc[0] - want_x).abs() < 1e-3 && (ndc[1] - want_y).abs() < 1e-3,
                    "yaw={yaw} pitch={pitch} point={point:?}: got {ndc:?} vs [{want_x}, {want_y}]"
                );
            }
        }
    }

    #[test]
    fn tap_and_hold_classifiers_follow_bedrock_tap_to_interact_rules() {
        use horizon_client::gameplay_guide::{Facts, Target, Verb};
        // Entity with interact verb (villager trade, horse ride, animal feed) -> Right.
        let villager = Facts {
            target: Target::Entity {
                attackable: true,
                takes: Some(Verb::Trade),
            },
            ..Facts::default()
        };
        assert_eq!(super::super::classify_world_tap(&villager), MouseButton::Right);
        // Hostile mob with no interact verb -> Left (attack).
        let zombie = Facts {
            target: Target::Entity {
                attackable: true,
                takes: None,
            },
            ..Facts::default()
        };
        assert_eq!(super::super::classify_world_tap(&zombie), MouseButton::Left);
        // Chest or door -> Right (open/use).
        let chest = Facts {
            target: Target::Block {
                breakable: true,
                takes: Some(Verb::Open),
            },
            ..Facts::default()
        };
        assert_eq!(super::super::classify_world_tap(&chest), MouseButton::Right);
        // Stone while holding a placeable block -> Right on tap, Left (mine) on hold!
        let stone_with_block = Facts {
            target: Target::Block {
                breakable: true,
                takes: None,
            },
            item_use: Some(Verb::Place),
            ..Facts::default()
        };
        assert_eq!(
            super::super::classify_world_tap(&stone_with_block),
            MouseButton::Right
        );
        assert_eq!(
            super::super::classify_world_hold(&stone_with_block),
            MouseButton::Left
        );
        // Stone while holding a pickaxe -> Left on tap and Left on hold.
        let stone_with_pick = Facts {
            target: Target::Block {
                breakable: true,
                takes: None,
            },
            item_use: None,
            ..Facts::default()
        };
        assert_eq!(
            super::super::classify_world_tap(&stone_with_pick),
            MouseButton::Left
        );
        assert_eq!(
            super::super::classify_world_hold(&stone_with_pick),
            MouseButton::Left
        );
        // Air while holding food/bow/shield -> Right on hold!
        let eating = Facts {
            target: Target::None,
            item_use: Some(Verb::Eat),
            ..Facts::default()
        };
        assert_eq!(super::super::classify_world_hold(&eating), MouseButton::Right);
    }
}
