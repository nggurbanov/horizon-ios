// horizon-ios: the contract between the touch overlay (Objective-C, adapted from Amethyst-iOS)
// and the game (Rust, crates/horizon-ios/src/bridge.rs). Keep both sides in step.
//
// Everything here runs on the main thread.
#pragma once

#include <stdbool.h>
#include <stdint.h>

// ---- Implemented in Rust (src/bridge.rs) ----

// A GLFW key (GLFW_KEY_*, glfw_keycodes.h) pressed (action 1), released (0) or repeated (2).
// `mods` is GLFW's modifier mask. Unknown keys are ignored.
void CallbackBridge_nativeSendKey(int key, int scancode, int action, int mods);
// A character typed with no key (the on-screen keyboard). Returns true when it was taken.
bool CallbackBridge_nativeSendChar(uint32_t codepoint);
bool CallbackBridge_nativeSendCharMods(uint32_t codepoint, int mods);
// A GLFW mouse button (0 left, 1 right, 2 middle) pressed (1) or released (0).
void CallbackBridge_nativeSendMouseButton(int button, int action, int mods);
// The pointer, in physical pixels of the game view, as in Amethyst:
// ACTION_DOWN / ACTION_UP / ACTION_MOVE (0, 1, 2): an absolute position.
// ACTION_MOVE_MOTION (3): a relative move; while grabbing it turns the view.
void CallbackBridge_nativeSendCursorPos(int event, double x, double y);
// Wheel offsets in lines, GLFW's sign (positive y scrolls up).
void CallbackBridge_nativeSendScroll(double xoffset, double yoffset);
// The view's size in physical pixels. Informational: the game reads its own window size.
void CallbackBridge_nativeSendScreenSize(int width, int height);
// Whether the game holds the pointer (playing, no screen open): touches then turn the view,
// as Amethyst's `isGrabbing`.
bool horizon_ios_is_grabbing(void);
// The GLFW key of the hotbar slot (GLFW_KEY_1 ... GLFW_KEY_9) under a point of the view in
// physical pixels, or -1 when the point is not on the hotbar or no world is shown.
int callback_SurfaceViewController_touchHotbar(double x, double y);

// ---- Implemented in Objective-C (the overlay) ----

// Called once for each game window the game creates, on the main thread, with winit's UIView
// (the Metal view the game draws into). The overlay puts its touch controls over it.
void horizon_ios_attach_overlay(void *ui_view);
