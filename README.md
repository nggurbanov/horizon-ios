# Horizon iOS

> [!IMPORTANT]
> **Unofficial native iOS port** of [Horizon](https://github.com/horizon-rust/horizon) (Minecraft: Java Edition 26.3 rewritten in Rust — native arm64 + Metal, **no JVM, no JIT**). Not affiliated with or endorsed by the Horizon Team, Mojang, or Microsoft. Report issues in this repository, not upstream.
>
> **Heads up:** This iOS port is **entirely vibe-coded (AI-built) and very experimental** — expect bugs and rough edges, and back up your worlds before playing.
>
> **License:** [LGPL-3.0-or-later](LICENSE). Ships zero Mojang files — you need your own copy of Minecraft: Java Edition 26.3.

## What's included

- **Native Rust AOT + Metal:** Runs directly on arm64 iOS 15+ (A12 chip or newer recommended) with **no JVM, no JIT, and no StikDebug required**.
- **Built-in Mod & Pack Browser + WASM code mods (no JIT):** Browse, search, install, update, toggle, and reorder **Horizon Registry** content & WebAssembly code mods (executed via Wasmtime's **Pulley64** bytecode interpreter — no JIT required), **Horizon shaders**, and **Modrinth** Resource Packs & per-world Data Packs directly inside the Pre-Launcher with SHA-256 / SHA-512 verification.
- **Bedrock-style native UIKit controls + instant input switching:** 1:1 mobile Bedrock touch controls with 3 schemes (Joystick + Crosshair, Joystick + Tap to Interact, Classic D-Pad), contextual Fly/Swim/Elytra/Dismount buttons, haptics, and optional gyro — switching immediately to Game Controllers (`GCController` + `CoreHaptics`) or Bluetooth/USB Mouse & Keyboard (`GCMouse`/`GCKeyboard` + pointer lock) the moment you press a button or move the mouse.
- **Native UIKit landscape Pre-Launcher:** 1-tap quick-join for servers and local worlds, live server ping, per-server Auto-Login command templates stored in Keychain, pre-launch `options.txt` graphics presets, built-in Mods & Packs browser/manager, in-app resource/pack importer, built-in log viewer & share sheet, automatic EN/RU localization, and a Skip Launcher toggle.
- **Built-in OTA updates:** AltStore Source v2 feed (`source.json`) with 1-tap updates via **Feather**, **SideStore**, **AltStore**, or direct `.ipa` download in Safari.

## Install (OTA & Direct `.ipa`)

- **OTA Source JSON (AltStore Source v2):**
  ```text
  https://github.com/nggurbanov/horizon-ios/releases/download/ios-latest/source.json
  ```
- **Feather:** Add the Source JSON URL above, or open `feather://source/https://github.com/nggurbanov/horizon-ios/releases/download/ios-latest/source.json` on your device.
- **SideStore:** Add the Source JSON URL above, or open `sidestore://source?url=https%3A%2F%2Fgithub.com%2Fnggurbanov%2Fhorizon-ios%2Freleases%2Fdownload%2Fios-latest%2Fsource.json`.
- **AltStore:** Add the Source JSON URL above, or open `altstore://source?url=https%3A%2F%2Fgithub.com%2Fnggurbanov%2Fhorizon-ios%2Freleases%2Fdownload%2Fios-latest%2Fsource.json`.
- **LiveContainer / Direct `.ipa`:** Download `Horizon.ipa` directly from the [`ios-latest` release](https://github.com/nggurbanov/horizon-ios/releases/tag/ios-latest).

> [!NOTE]
> **`increased-memory-limit` entitlement:** Paid signing certificates, **Feather**, **AltStore 2.2+**, **LiveContainer**, and **TrollStore** preserve `com.apple.developer.kernel.increased-memory-limit` automatically. On **SideStore** with a free Apple ID, add the entitlement with [GetMoreRam](https://github.com/hugeBlack/GetMoreRam) before reinstalling so iOS doesn't cap RAM at half the device's memory.

## Game Assets

This app ships zero Mojang files. Prepare assets once from your own copy of Minecraft: Java Edition 26.3:

1. Run official desktop [Horizon](https://playhorizon.dev) once on a PC/Mac with your copy of Minecraft: Java Edition 26.3 so it prepares the `26.3` folder (or run `horizon-prepare --prepare` from source — see [docs/native-client.md](docs/native-client.md)).
2. Compress that `26.3` folder to a `.zip` and send it to your iPhone (AirDrop, iCloud Drive, or Files).
3. Open Horizon on iPhone → **Files → Import…** and select the `.zip` (or the uncompressed folder).

## Current limitations

- Singleplayer, LAN, and offline-mode servers work today. Microsoft online sign-in is not enabled in this fork because upstream Horizon's Azure App ID is reserved for official builds ([docs/forking.md](docs/forking.md)).
- Requires iOS 15 or later (A12 chip or newer recommended).
- Horizon content mods (`.hmod`) and WebAssembly code mods run on iOS via Wasmtime Pulley64 without JIT; desktop-only native Rust dylib mods (`native-mod`) cannot run on iOS.

## Upstream & technical docs

All of the underlying Rust Minecraft engine is built by the **Horizon Team** ([horizon-rust/horizon](https://github.com/horizon-rust/horizon) · [playhorizon.dev](https://playhorizon.dev)).

See **[HORIZON-IOS.md](HORIZON-IOS.md)** for the full controls breakdown, Pre-Launcher & Auto-Login details, architecture map, crash-report instructions, and building from source.

---

<sub>Horizon and `horizon-ios` are distributed under the [GNU LGPL, version 3 or later](LICENSE). Third-party dependencies keep their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).</sub>

<sub>NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG OR MICROSOFT. Minecraft is a trademark of Mojang Synergies AB; its code and assets belong to Mojang and Microsoft under the [Minecraft EULA](https://www.minecraft.net/en-us/eula).</sub>
