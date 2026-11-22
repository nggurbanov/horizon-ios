# horizon-ios

An unofficial iOS port of [Horizon](https://github.com/horizon-rust/horizon) with a native UIKit
control system modeled 1:1 on official mobile Minecraft Bedrock, plus instant auto-switching
between Touch, Game Controller (console mode), and Mouse + Keyboard (PC mode). It's not
affiliated with the Horizon Team, Mojang or Microsoft.

**Status: experimental, running on device.** Tested under LiveContainer and AltStore on iOS 15+.

## Install

1. Download `Horizon.ipa` from the [`ios-latest` release](../../releases/tag/ios-latest) (or build
   it locally).
2. Sideload it. With a free Apple ID, use **AltStore 2.2 or later** or **LiveContainer**: they keep
   the app's `com.apple.developer.kernel.increased-memory-limit` entitlement, without which iOS
   stops the game at about half the device's memory. SideStore keeps it only after you add
   "Increased Memory Limit" to the app's App ID with [GetMoreRam](https://github.com/hugeBlack/GetMoreRam)
   and reinstall; Sideloadly drops it. TrollStore and paid developer accounts keep it too.
   - iOS 15 or later on an iPhone or iPad with an A12 chip or newer.
   - A free Apple ID's apps expire after 7 days: refresh them in AltStore.
   - No JIT or StikDebug needed: Horizon is compiled ahead of time. (WebAssembly code mods
     would need JIT; they aren't supported on iOS yet.)

## The game files

Like Horizon on desktop, the app ships none of Mojang's files: you need your own copy of
Minecraft: Java Edition.

1. On a computer, prepare the files as for desktop Horizon (`horizon-prepare --prepare`,
   [docs/native-client.md](docs/native-client.md)). They end up in
   `.local/horizon-client/26.3`.
2. Copy the **contents** of that `26.3` folder into the app's `resources` folder. You can do this
   in Finder (select the device, then Files, then Horizon) or in the Files app (On My
   iPhone, then Horizon, then `resources`). `resources/horizon-resources.json` must exist.
3. Start the app. Without the files it shows where it looked.

The app's `Documents` folder is the game folder, so saves, `options.txt`, and screenshots live
there. In LiveContainer it's the app's data folder (`LiveContainer → Data → Application → Horizon → Documents`).

**If it crashes,** send `Documents/horizon-log.txt` (this launch's output; the last launch's is
`horizon-log.previous.txt`), anything in `Documents/horizon/` (logs and crash reports), and the
iOS crash report: Settings → Privacy & Security → Analytics & Improvements → Analytics Data,
the newest `Horizon-…` or, under LiveContainer, `LiveContainer-…` entry.

## Controls

`horizon-ios` supports three native input modes and switches between them instantaneously without
restarting or opening settings:

- **Touch (Bedrock 1:1)** — active whenever you touch the screen:
  - **Three official Bedrock control schemes** (switchable live via the top-bar gear button, saved
    in `NSUserDefaults`):
    1. **Joystick & Aim Crosshair** *(default)* — 360° analog joystick with floating/fixed mode,
       forward auto-sprint, pull-up auto-sprint lock, central crosshair, and ergonomic Jump / Sneak /
       Attack (sword on mobs, pickaxe on blocks) / Interact buttons.
    2. **Joystick & Tap to Interact** — 360° analog joystick with central crosshair hidden; tap
       anywhere in the 3D world to hit mobs, place blocks, or open containers via screen-space
       raycast; hold on a block to mine with the expanding circular break indicator (slide onto
       neighboring blocks to keep mining), or hold to eat/draw a bow/raise a shield; floating
       contextual pill above the hotbar (Open, Mount, Trade, Sleep, Eat, etc.).
    3. **Classic D-Pad & Tap to Interact** — traditional Minecraft Pocket cross D-Pad with dynamic
       diagonal arrows, double-tap forward to sprint, center Sneak (or swapped Jump), and Tap to
       Interact.
  - **Contextual movement buttons** — Jump/Sneak automatically switch to stacked hold-only **Fly Up /
    Fly Down** while flying (releasing Sneak cleanly on landing), **Swim Up / Swim Down** underwater,
    **Elytra** glide, and **Dismount** (plus mount jump when riding a horse/camel).
  - **Top mini-bar** — centered Pause (`⏸`), Chat (`💬`), Perspective (`F5`), and Quick Touch
    Settings (`⚙`: scheme, floating joystick, auto-jump, left-handed, swap jump/sneak, button scale,
    opacity, camera sensitivity, haptics, optional gyroscope aiming).
  - **Hotbar & Inventory** — tap or swipe across the live game hotbar to pick slots, hold a slot
    for the green progress bar to drop one item or the whole stack, and tap the flush `⋯` button
    beside the hotbar to open Inventory. Inside inventories and chests, gameplay controls hide and
    you get a top-right `✕`, left-side **Shift (Quick Move)** and **Drop** toggles, direct tap/drag,
    two-finger scroll, and the green hold-to-split-stack bar.
  - **Chat & Auto-Keyboard** — focusing any in-game text field (chat, signs, books, anvil, search,
    server address) opens the iOS keyboard automatically and closes it on blur. In chat, a native
    top bar (`✕`, text input synced with Horizon, `Tab`, `↑`, `↓`, `Send`) stays cleanly at the top
    while chat history and command suggestions lift above the keyboard.
  - **Touch Auto-Jump & Haptics** — Auto-Jump is enabled by default in Touch mode (independent of
    desktop/gamepad settings) and tactile feedback (`UIImpactFeedbackGenerator`) triggers on taps,
    block breaks, stack splits, explosions, and totems.
- **Game Controller (Console Mode)** — press any button or move a stick on an Xbox, DualSense /
  DualShock, Nintendo Switch Pro, Backbone, or MFi controller (`GCController`) to immediately hide
  the touch HUD and hand off to Horizon's native controller UI, glyph prompts, radial menus, and
  `CoreHaptics` rumble.
- **Mouse & Keyboard (PC Mode)** — move a Bluetooth/USB mouse (`GCMouse`) or press a hardware
  keyboard key (`GCKeyboard` / `UIPress`) to immediately hide the touch HUD and play with full PC
  controls and iOS pointer lock (`prefersPointerLocked`) during gameplay.

## How it fits together

| Part | Where |
|---|---|
| App entry, game folder & log redirect, C ABI bridge, USB HID map | `crates/horizon-ios/src/` |
| Native UIKit Bedrock overlay, `GCController`, `GCMouse`/`GCKeyboard`, `CoreHaptics`, `CoreMotion`, quick settings | `crates/horizon-ios/objc/` |
| C ABI contract between Rust and Objective-C | `crates/horizon-ios/objc/horizon_bridge.h` |
| Input mode state, gameplay facts, hotbar metrics, haptics/rumble & gamepad queues, iOS auto GUI scale | `crates/horizon-client-input/src/{touch_bridge,window}.rs` |
| Screen-space raycast, tap/hold classifiers, Touch Auto-Jump, iOS `GCController` feed, keyboard-aware chat layout | `crates/horizon-client/src/game/` |
| Window hosting on iOS | `third_party/winit` (winit 0.30.13, changes marked `horizon-ios`) |
| IPA build | `.github/workflows/ios-ipa.yml` |

Every change to Horizon's own files is marked with a `horizon-ios` comment, so merges from
upstream stay readable.

## Licence

All code in `crates/horizon-ios` (both Rust and Objective-C) is original and distributed under
Horizon's [LGPL-3.0-or-later](LICENSE) licence. The legacy Amethyst-iOS GPL-3.0 touch overlay has
been completely removed.
