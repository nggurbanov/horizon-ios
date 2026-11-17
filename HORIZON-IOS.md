# horizon-ios

An unofficial iOS port of [Horizon](https://github.com/horizon-rust/horizon), with on-screen touch
controls adapted from [Amethyst-iOS](https://github.com/AngelAuraMC/Amethyst-iOS). It's not
affiliated with the Horizon Team, the Amethyst/PojavLauncher teams, Mojang or Microsoft.

**Status: experimental.** It builds in CI. Running it on a device is the open question.

## Install

1. Download `Horizon.ipa` from the [`ios-latest` release](../../releases/tag/ios-latest).
2. Sideload it. With a free Apple ID, use **AltStore 2.2 or later**: it keeps the app's
   increased-memory-limit entitlement, without which iOS stops the game at about half the
   device's memory. SideStore keeps it only after you add "Increased Memory Limit" to the app's
   App ID with [GetMoreRam](https://github.com/hugeBlack/GetMoreRam) and reinstall; Sideloadly
   drops it. TrollStore and paid developer accounts keep it too.
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

The app's Documents folder is the game folder, so saves, `options.txt`, screenshots and
`controlmap/` (the touch control layouts) are there. In LiveContainer it's the app's data
folder (LiveContainer → Data → Application → Horizon's folder → Documents).

**If it crashes,** send `Documents/horizon-log.txt` (this launch's output; the last launch's is
`horizon-log.previous.txt`), anything in `Documents/horizon/` (logs and crash reports), and the
iOS crash report: Settings → Privacy & Security → Analytics & Improvements → Analytics Data,
the newest `Horizon-…` or, under LiveContainer, `LiveContainer-…` entry.

## Controls

- **Look:** drag on an empty part of the screen.
- **Break / attack:** tap, or hold to keep mining.
- **Use / place:** use the on-screen buttons.
- **Hotbar:** swipe along it to pick a slot.
- **Menus:** a virtual mouse.
- **Layouts:** `Documents/controlmap/default.json`, in Amethyst's format, so Amethyst and
  PojavLauncher layouts work. The in-app layout editor isn't ported yet.
- **Gyroscope aiming:** off by default (`control.gyroscope_enable`).
- **Hardware:** keyboards, mice and game controllers work too.

## How it fits together

| Part | Where |
|---|---|
| The app: sets the game folder, starts the official game, attaches the overlay | `crates/horizon-ios/src/` |
| Touch overlay (Objective-C, from Amethyst) | `crates/horizon-ios/objc/` |
| The C contract between them | `crates/horizon-ios/objc/horizon_bridge.h` |
| Touch input into the game, through its keyboard and mouse handlers | `crates/horizon-client-input/src/touch_bridge.rs`, `take_touch_input` in `game/runtime/window_handler.rs` |
| Synthetic key events and keyboard on iOS | `third_party/winit` (winit 0.30.13, changes marked `horizon-ios`) |
| IPA build | `.github/workflows/ios-ipa.yml` |

Every change to Horizon's own files is marked with a `horizon-ios` comment, so merges from
upstream stay readable.

## Licence

Horizon's files keep their LGPL-3.0-or-later licence. The overlay in `crates/horizon-ios/objc`
comes from Amethyst-iOS (GPL-3.0), so the iOS app as a whole is distributed under the
[GPL-3.0](LICENSES/GPL-3.0.txt). Anyone you give the app to can ask you for its source: it's this
repository.
