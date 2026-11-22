# horizon-ios

An unofficial native iOS port of [Horizon](https://github.com/horizon-rust/horizon) (Minecraft: Java
Edition 26.3 rewritten in Rust — arm64 + Metal, no JVM, no JIT) featuring a native UIKit landscape
Pre-Launcher, 1:1 Bedrock-style touch controls, instant auto-switching to Game Controllers and
Mouse + Keyboard, and built-in OTA updates. Not affiliated with or endorsed by the Horizon Team,
Mojang, or Microsoft.

> [!WARNING]
> **Experimental & AI-built:** This iOS port is **entirely vibe-coded (AI-built) and very
> experimental** — expect bugs and rough edges, and back up your worlds before playing. Report iOS
> issues in this fork, not upstream.

## Install & OTA Updates

`horizon-ios` publishes an **AltStore Source v2** manifest (`source.json`) alongside every
[`ios-latest`](../../releases/tag/ios-latest) build, supporting **Feather**, **SideStore**, and
**AltStore** as well as direct `.ipa` sideloading:

- **OTA Source JSON:** `https://github.com/nggurbanov/horizon-ios/releases/download/ios-latest/source.json`
- **Feather:** add the Source JSON URL above (`feather://source/<source-url>`), or tap **+ Feather**
  inside the Pre-Launcher's **Files** tab.
- **SideStore:** add the Source JSON URL above (`sidestore://source?url=<encoded-source-url>`), or
  tap **+ SideStore** inside the Pre-Launcher's **Files** tab.
- **AltStore:** add the Source JSON URL above (`altstore://source?url=<encoded-source-url>`).
- **Direct `.ipa` / LiveContainer:** download `Horizon.ipa` from the
  [`ios-latest` release](../../releases/tag/ios-latest) (or build it locally).

Inside the Pre-Launcher, **Horizon automatically checks `source.json` on startup** (configurable)
and displays an update banner on the Home tab when a newer version/build is available. Tapping
**Update** routes to your preferred installer (`Auto`, `Feather`, `SideStore`, `AltStore`, or
`Safari`), auto-detecting installed sideloaders in `Auto` mode.

### Entitlement & device notes

- **`com.apple.developer.kernel.increased-memory-limit`:** Paid signing certificates, **Feather**,
  **AltStore 2.2+**, **LiveContainer**, and **TrollStore** keep this entitlement automatically.
  Without it, iOS terminates the game at roughly half of physical RAM. On **SideStore** with a free
  Apple ID, enable "Increased Memory Limit" on the App ID with
  [GetMoreRam](https://github.com/hugeBlack/GetMoreRam) and reinstall; Sideloadly drops it.
- **Requirements:** iOS 15 or later on an iPhone or iPad with an A12 chip or newer.
- **No JIT / StikDebug required:** Horizon compiles ahead of time to native arm64 + Metal.
  (WebAssembly code mods would require JIT and are not enabled on iOS yet.)
- **7-day signing window:** Free Apple ID installs expire after 7 days unless refreshed.

## The game files

Like desktop Horizon, the app ships zero Mojang files — you need your own copy of Minecraft: Java
Edition 26.3.

### Option A: In-app import (recommended)

1. Run official desktop [Horizon](https://playhorizon.dev) once on a PC/Mac with your own copy of
   Minecraft: Java Edition 26.3 so it prepares the `26.3` folder (or run `horizon-prepare --prepare`
   from source, see [docs/native-client.md](docs/native-client.md); files land in
   `.local/horizon-client/26.3`).
2. Compress that `26.3` folder into a `.zip` archive and transfer it to your iPhone (AirDrop,
   iCloud Drive, or Files).
3. Open Horizon on iPhone → **Files → Import…** and pick the `.zip` (or uncompressed folder). Nested
   wrapper folders inside `.zip` archives are stripped automatically so `horizon-resources.json`
   lands at `Documents/resources/horizon-resources.json`.

### Option B: Manual Files / Finder copy

Copy the **contents** of the prepared `26.3` folder directly into the app's `Documents/resources/`
directory via Finder (select device → Files → Horizon) or the iOS Files app (**On My iPhone →
Horizon → `resources`**). `Documents/resources/horizon-resources.json` must exist.

The app's `Documents` directory is the game folder (`saves/`, `options.txt`, `servers.dat`,
`resourcepacks/`, `shaderpacks/`, screenshots). Under LiveContainer, it lives at
`LiveContainer → Data → Application → Horizon → Documents`.

### Logs & crash reports

You can view and export logs directly from the Pre-Launcher (**Files → Launch Logs & Crash
Reports → Open / Share**), or grab them manually from `Documents/`:

- `Documents/horizon-log.txt` (current launch) and `Documents/horizon-log.previous.txt` (previous
  launch)
- `Documents/horizon/` (Horizon logs and crash reports)
- iOS crash report: **Settings → Privacy & Security → Analytics & Improvements → Analytics Data**
  (newest `Horizon-…` or `LiveContainer-…` entry)

## Pre-Launcher & Per-Server Auto-Login

On startup, Horizon opens a fast native UIKit landscape split-view Pre-Launcher before initializing
Metal or loading game assets:

- **Home:** OTA update banner (when available), offline player nickname (`horizon-player.txt`),
  1-tap quick-join cards for your last server and newest local world, and pre-launch status tiles.
- **Servers:** Reads and edits Minecraft's native `servers.dat` (preserving server icons, resource
  pack preferences, and hidden entries), performs live Minecraft Server List Pings (SLP) for latency
  and player counts, lists local worlds from `Documents/saves/`, and launches straight into a server
  or world in one tap.
- **Per-Server Auto-Login:** Optional per-server login command templates (`/l {password}`,
  `/login {password}`, `/auth {password}`, or custom) with configurable post-join delay
  (`0.5s` / `1.0s` / `2.0s` / `3.0s`). Passwords are stored locally in the **iOS Keychain**
  (`kSecClassGenericPassword`, `ThisDeviceOnly`), with an automatic app-private fallback
  (`Library/Application Support/horizon-autologin.plist`, mode `0600`, never inside `Documents/`)
  when sideload environments lack Keychain entitlements (`-34018`). Passwords and rendered login
  commands are never logged and never added to chat history.
- **Controls:** Live connected-input indicator (Touch / Gamepad / Keyboard+Mouse) and full Bedrock
  touch customization synchronized with in-game Touch Settings.
- **Graphics:** Quick presets (**Battery** `6 chunks · 30 FPS`, **Balanced** `8 chunks · 60 FPS`,
  **Max** `12 chunks · 120 FPS`) plus Render Distance, Max FPS, GUI Scale, FOV, Game Language
  (`options.txt`, preserving all other keys verbatim), **Launcher Language** (`Auto` / `English` /
  `Русский` with instant UI refresh), and **Skip Launcher on Startup**.
- **Files & Diagnostics:** Resources import (`.zip` or folder), OTA update checker & installer
  selector, `.zip` import for resource packs and shaders, built-in monospace log & crash-report
  viewer + iOS share sheet, and live RAM / free storage / `increased-memory-limit` diagnostics.

## Controls

`horizon-ios` supports three native input modes and switches between them instantaneously without
restarting or opening settings:

- **Touch (Bedrock 1:1)** — active whenever you touch the screen:
  - **Three Bedrock control schemes** (switchable live via the top-bar gear button or Pre-Launcher,
    saved in `NSUserDefaults`):
    1. **Joystick & Aim Crosshair** *(default)* — 360° analog joystick with floating/fixed mode,
       forward auto-sprint, pull-up auto-sprint lock, central crosshair, and ergonomic Jump / Sneak /
       Attack (sword on mobs, pickaxe on blocks) / Interact buttons.
    2. **Joystick & Tap to Interact** — 360° analog joystick with central crosshair hidden; tap
       anywhere in the 3D world to hit mobs, place blocks, or open containers via screen-space
       raycast; hold on a block to mine with the expanding circular break indicator (slide onto
       neighboring blocks to keep mining), or hold to eat/draw a bow/raise a shield; floating
       contextual pill above the hotbar (Open, Mount, Trade, Sleep, Eat, etc.).
    3. **Classic D-Pad & Tap to Interact** — traditional Pocket cross D-Pad with dynamic diagonal
       arrows, double-tap forward to sprint, center Sneak (or swapped Jump), and Tap to Interact.
  - **Contextual movement buttons** — Jump/Sneak automatically switch to stacked hold-only **Fly Up /
    Fly Down** while flying (releasing Sneak cleanly on landing), **Swim Up / Swim Down** underwater,
    **Elytra** glide, and **Dismount** (plus mount jump when riding a horse/camel).
  - **Top mini-bar** — centered Pause, Chat, Perspective (`F5`), and Quick Touch Settings (scheme,
    floating joystick, auto-jump, left-handed, swap jump/sneak, button scale, opacity, camera
    sensitivity, haptics, optional gyroscope aiming, Show Launcher on Next Start).
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

## Building from source

On macOS with Xcode and the `aarch64-apple-ios` Rust target installed:

```sh
rustup target add aarch64-apple-ios
IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --profile fast --target aarch64-apple-ios -p horizon-ios
```

See [`.github/workflows/ios-ipa.yml`](.github/workflows/ios-ipa.yml) for packaging `Horizon.app`
into an ad-hoc-signed `Horizon.ipa` with `crates/horizon-ios/app/Info.plist`,
`crates/horizon-ios/app/entitlements.plist`, and generating `source.json` via
`tools/ios_ota_source.py`.

Note: `horizon-ios` runs `horizon-game` directly without `horizon-official` hooks (no official
Horizon heartbeat pings or desktop-only Discord Rich Presence) and does not embed upstream's Azure
App ID ([docs/forking.md](docs/forking.md)).

## How it fits together

| Part | Where |
|---|---|
| App entry (64 MiB stack via `stacker`), game folder & log redirect, C ABI bridge, USB HID map | `crates/horizon-ios/src/{main,host,bridge,hid}.rs` |
| Pure-Rust Pre-Launcher storage (`servers.dat`, `options.txt`, `horizon-player.txt`), SLP ping, world scan, resource `.zip` extractor, OTA version compare & deep-link builders | `crates/horizon-ios/src/prelauncher.rs` |
| Native UIKit 5-tab Pre-Launcher, Server Editor, Auto-Login Keychain store, OTA Updater, Log Viewer, automatic EN/RU localization (`HorizonL10n`) | `crates/horizon-ios/objc/{HorizonPreLauncher*,HorizonServerEditor*,HorizonAutoLoginStore*,HorizonOTAUpdater*,HorizonLogViewer*,HorizonL10n*}.{h,m}` |
| Native UIKit Bedrock touch overlay, `GCController`, `GCMouse`/`GCKeyboard`, `CoreHaptics`, `CoreMotion`, quick Touch Settings, hang watchdog | `crates/horizon-ios/objc/{HorizonOverlay*,HorizonTouch*,HorizonIcons*,HorizonGamepad*,HorizonMouseKeyboard*,HorizonSettings*,HangWatchdog}.{h,m}` |
| C ABI contract between Rust and Objective-C | `crates/horizon-ios/objc/horizon_bridge.h` |
| Input mode state, gameplay facts, hotbar metrics, haptics/rumble & gamepad queues, auto-login command renderer, iOS auto GUI scale | `crates/horizon-client-input/src/{touch_bridge,window}.rs` |
| Screen-space raycast, tap/hold classifiers, Touch Auto-Jump, iOS `GCController` feed, keyboard-aware chat layout, quick-join & auto-login execution | `crates/horizon-client/src/game/` |
| Window hosting on iOS | `third_party/winit` (winit 0.30.13, changes marked `horizon-ios`) |
| AltStore / SideStore / Feather Source v2 generator & CI IPA workflow | `tools/ios_ota_source.py`, `.github/workflows/ios-ipa.yml` |

Every change to Horizon's shared files is marked with a `horizon-ios` comment so merges from
upstream stay readable.

## License

All code in `crates/horizon-ios` (both Rust and Objective-C) is original and distributed under
Horizon's [LGPL-3.0-or-later](LICENSE) license.
