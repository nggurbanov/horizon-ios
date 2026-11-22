//! Pure-Rust Mod & Pack Browser / Manager backend for `horizon-ios`.
//!
//! Supports:
//! - Horizon Registry (`https://horizon-rust.github.io/horizon-mods/index.json`):
//!   `.hmod` content mods & WASM Pulley64 code mods, resource packs, shaders (`.hshader` +
//!   classic `.zip`), and data packs; native-mod entries are marked desktop-only and never
//!   installable on iOS.
//! - Modrinth API v2 (`https://api.modrinth.com/v2`): resource packs and data packs
//!   (identified in plain text `"Modrinth"` only, zero bundled Modrinth logo artwork).
//! - Verified atomic downloads (HTTPS host allowlist, strict filename sanitization,
//!   `.<name>.part` streaming with SHA-256 / SHA-512 verification, package validation).
//! - 1:1 game config wiring: `horizon-mods.txt`, `options.txt` (`resourcePacks`),
//!   `horizon-graphics.txt` (`pickedShaderPack`), `saves/<world>/datapacks.json`, and
//!   `mod-browser.json` install/update tracking + bounded 64 MiB icon cache.

use crate::prelauncher::{self, LocalWorldInfo};
use horizon_mod_package::{
    Package,
    index::{self, Index},
    mod_list::{self, ModList},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256, Sha512};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::{LazyLock, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

pub const HORIZON_INDEX_URL: &str = "https://horizon-rust.github.io/horizon-mods/index.json";
pub const HORIZON_SITE_URL: &str = "https://playhorizon.dev/mods";
pub const MODRINTH_API_URL: &str = "https://api.modrinth.com/v2";
pub const MODRINTH_SITE_URL: &str = "https://modrinth.com";
pub const GAME_VERSION: &str = "26.3";

pub const USER_AGENT: &str = concat!(
    "horizon-ios/",
    env!("CARGO_PKG_VERSION"),
    " (https://github.com/nggurbanov/horizon-ios)"
);

pub const MANIFEST_FILE: &str = "mod-browser.json";
pub const INDEX_CACHE_REL: &str = "mod-browser/horizon-index.json";
pub const IMAGES_CACHE_REL: &str = "mod-browser/images";
pub const GRAPHICS_FILE: &str = "horizon-graphics.txt";
pub const OPTIONS_FILE: &str = "options.txt";
pub const DATAPACKS_FILE: &str = "datapacks.json";

const INDEX_TTL: Duration = Duration::from_secs(600);
const MAX_INDEX_BYTES: u64 = 16 << 20;
const MAX_DOWNLOAD_BYTES: u64 = 512 << 20;
const MAX_ICON_BYTES: u64 = 4 << 20;
const ICON_CACHE_MAX_BYTES: u64 = 64 << 20;

const MODRINTH_RP_CATEGORIES: &[&str] = &[
    "16x",
    "32x",
    "64x",
    "128x",
    "vanilla-like",
    "realistic",
    "simplistic",
    "themed",
    "tweaks",
    "utility",
    "gui",
    "audio",
    "blocks",
    "entities",
    "environment",
    "items",
    "models",
    "combat",
];

const MODRINTH_DP_CATEGORIES: &[&str] = &[
    "adventure",
    "decoration",
    "economy",
    "equipment",
    "food",
    "game-mechanics",
    "magic",
    "mobs",
    "optimization",
    "storage",
    "technology",
    "transportation",
    "utility",
    "worldgen",
];

/// Shared HTTP agent using rustls + webpki-roots (no OpenSSL/native TLS dependency on iOS).
fn http_agent() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| {
        ureq::AgentBuilder::new()
            .user_agent(USER_AGENT)
            .timeout_connect(Duration::from_secs(15))
            .timeout_read(Duration::from_secs(60))
            .build()
    })
}

/// Process-wide cache of the latest parsed Horizon Registry index, keyed by game dir.
static INDEX_MEM_CACHE: LazyLock<Mutex<HashMap<PathBuf, (Instant, Index)>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

// ============================================================================
// Security: HTTPS host allowlist, filename sanitization, verified downloads
// ============================================================================

/// Extracts the lowercased hostname from an `https://` URL, rejecting credentials (`@`),
/// whitespace, control chars, or non-443 explicit ports.
fn https_host(url: &str) -> Option<String> {
    let rest = url.strip_prefix("https://")?;
    if rest.is_empty() || url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next()?;
    if authority.is_empty() || authority.contains('@') {
        return None;
    }
    let host = match authority.split_once(':') {
        Some((h, "443")) => h,
        Some(_) => return None,
        None => authority,
    };
    if host.is_empty() {
        return None;
    }
    Some(host.to_ascii_lowercase())
}

/// Matches `https://github.com/<owner>/<repo>/releases/download/<tag>/<name>`
/// (matching `launcher/src/browser/download.rs::github_release_asset`).
pub fn is_github_release_asset(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://github.com/") else {
        return false;
    };
    if url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return false;
    }
    let path_only = rest.split(['?', '#']).next().unwrap_or(rest);
    let parts: Vec<&str> = path_only.split('/').collect();
    let plain = |p: &str| {
        !p.is_empty()
            && p != "."
            && p != ".."
            && p.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'+' | b'%'))
    };
    matches!(
        parts.as_slice(),
        [owner, repo, "releases", "download", tag, name]
            if [owner, repo, tag, name].iter().all(|p| plain(p))
    )
}

/// Enforces the HTTPS download host allowlist matching `launcher/src/browser/download.rs`.
pub fn is_allowed_download_url(url: &str) -> bool {
    let Some(host) = https_host(url) else {
        return false;
    };
    match host.as_str() {
        "cdn.modrinth.com"
        | "horizon-rust.github.io"
        | "objects.githubusercontent.com"
        | "release-assets.githubusercontent.com" => true,
        "github.com" => is_github_release_asset(url),
        _ => false,
    }
}

/// Enforces the HTTPS host allowlist for project icons.
pub fn is_allowed_image_url(url: &str) -> bool {
    let Some(host) = https_host(url) else {
        return false;
    };
    matches!(
        host.as_str(),
        "cdn.modrinth.com"
            | "horizon-rust.github.io"
            | "objects.githubusercontent.com"
            | "avatars.githubusercontent.com"
    )
}

/// Validates a single plain filename: no path separators, no `..`, no leading dot, no control chars.
pub fn is_safe_filename(name: &str) -> bool {
    if name.is_empty() || name.len() > 160 || name.starts_with('.') {
        return false;
    }
    if name == "." || name == ".." || name.contains("..") {
        return false;
    }
    if name
        .chars()
        .any(|c| matches!(c, '/' | '\\' | ':' | '\0') || c.is_control())
    {
        return false;
    }
    let mut comps = Path::new(name).components();
    matches!(comps.next(), Some(Component::Normal(_))) && comps.next().is_none()
}

/// Validates a single plain world folder name inside `saves/`.
pub fn is_safe_world_folder(name: &str) -> bool {
    if name.is_empty() || name.len() > 160 || name == "." || name == ".." {
        return false;
    }
    if name
        .chars()
        .any(|c| matches!(c, '/' | '\\' | '\0') || c.is_control())
    {
        return false;
    }
    let mut comps = Path::new(name).components();
    matches!(comps.next(), Some(Component::Normal(_))) && comps.next().is_none()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChecksumAlgo {
    Sha256,
    Sha512,
}

impl ChecksumAlgo {
    pub fn label(self) -> &'static str {
        match self {
            Self::Sha256 => "SHA-256",
            Self::Sha512 => "SHA-512",
        }
    }

    fn expected_hex_len(self) -> usize {
        match self {
            Self::Sha256 => 64,
            Self::Sha512 => 128,
        }
    }
}

fn is_valid_hex(s: &str, expected_len: usize) -> bool {
    s.len() == expected_len && s.bytes().all(|b| b.is_ascii_hexdigit())
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        use std::fmt::Write as _;
        let _ = write!(&mut out, "{b:02x}");
    }
    out
}

/// Streams `reader` into `<dest_dir>/.<filename>.part`, checks exact size (when `expected_size > 0`)
/// and cryptographic checksum, and atomically renames into `<dest_dir>/<filename>`.
/// Always deletes the `.part` file on error.
pub fn download_verified_from_reader(
    mut reader: impl Read,
    dest_dir: &Path,
    filename: &str,
    expected_size: u64,
    algo: ChecksumAlgo,
    expected_hex: &str,
) -> Result<PathBuf, String> {
    if !is_safe_filename(filename) {
        return Err(format!("Unsafe filename refused: {filename:?}"));
    }
    let expected_hex = expected_hex.trim();
    if !is_valid_hex(expected_hex, algo.expected_hex_len()) {
        return Err(format!(
            "Refusing download without a valid {} checksum",
            algo.label()
        ));
    }
    if expected_size > MAX_DOWNLOAD_BYTES {
        return Err("File exceeds maximum allowed download size".into());
    }
    fs::create_dir_all(dest_dir).map_err(|e| format!("{}: {e}", dest_dir.display()))?;
    let target = dest_dir.join(filename);
    let part = dest_dir.join(format!(".{filename}.part"));

    let res = (|| -> Result<(), String> {
        let mut out = fs::File::create(&part).map_err(|e| format!("{}: {e}", part.display()))?;
        let mut sha256 = (algo == ChecksumAlgo::Sha256).then(Sha256::new);
        let mut sha512 = (algo == ChecksumAlgo::Sha512).then(Sha512::new);
        let mut buf = vec![0u8; 64 * 1024];
        let mut written = 0u64;
        loop {
            let n = reader
                .read(&mut buf)
                .map_err(|e| format!("Download interrupted: {e}"))?;
            if n == 0 {
                break;
            }
            written = written.saturating_add(n as u64);
            if written > MAX_DOWNLOAD_BYTES || (expected_size > 0 && written > expected_size) {
                return Err("Downloaded file is larger than declared by source".into());
            }
            if let Some(h) = sha256.as_mut() {
                h.update(&buf[..n]);
            }
            if let Some(h) = sha512.as_mut() {
                h.update(&buf[..n]);
            }
            out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        }
        if expected_size > 0 && written != expected_size {
            return Err(format!(
                "Incomplete download: received {written} of {expected_size} bytes"
            ));
        }
        let actual_hex = match (sha256, sha512) {
            (Some(h), _) => hex_lower(&h.finalize()),
            (_, Some(h)) => hex_lower(&h.finalize()),
            _ => unreachable!(),
        };
        if !actual_hex.eq_ignore_ascii_case(expected_hex) {
            return Err(format!(
                "{} checksum mismatch: nothing was installed",
                algo.label()
            ));
        }
        out.sync_all().map_err(|e| e.to_string())?;
        drop(out);
        fs::rename(&part, &target).map_err(|e| format!("{}: {e}", target.display()))
    })();

    if res.is_err() {
        let _ = fs::remove_file(&part);
    }
    res.map(|()| target)
}

/// Downloads an HTTPS URL from an allowlisted host with verified checksum into `dest_dir`.
pub fn download_verified_url(
    url: &str,
    dest_dir: &Path,
    filename: &str,
    expected_size: u64,
    algo: ChecksumAlgo,
    expected_hex: &str,
) -> Result<PathBuf, String> {
    if !is_allowed_download_url(url) {
        return Err(format!("Download host is not on the allowlist: {url}"));
    }
    let response = http_agent().get(url).call().map_err(|e| match e {
        ureq::Error::Status(code, _) => format!("Server returned HTTP {code}"),
        ureq::Error::Transport(t) => format!("Network error: {t}"),
    })?;
    let final_url = response.get_url().to_owned();
    if !is_allowed_download_url(&final_url) {
        return Err(format!(
            "Redirected download host is not on the allowlist: {final_url}"
        ));
    }
    download_verified_from_reader(
        response.into_reader(),
        dest_dir,
        filename,
        expected_size,
        algo,
        expected_hex,
    )
}

// ============================================================================
// Game Config Wiring: horizon-mods.txt, options.txt, horizon-graphics.txt,
// saves/<world>/datapacks.json
// ============================================================================

fn write_atomic_text(path: &Path, body: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("config");
    let tmp = path.with_file_name(format!(".{name}.tmp.{}", std::process::id()));
    fs::write(&tmp, body)?;
    fs::rename(&tmp, path)
}

/// Enables or disables a mod ID in `Documents/horizon-mods.txt` using Horizon's `ModList` format.
pub fn set_mod_enabled(game_dir: &Path, mod_id: &str, enabled: bool) -> Result<(), String> {
    let mod_id = mod_id.trim();
    if mod_id.is_empty() || mod_id.contains(['\n', '\r', ':', '/', '\\']) {
        return Err("Invalid mod id".into());
    }
    let mut list = ModList::load(game_dir);
    if enabled {
        list.disabled.remove(mod_id);
        list.enabled.insert(mod_id.to_owned());
    } else {
        list.enabled.remove(mod_id);
    }
    let path = game_dir.join(mod_list::FILE);
    write_atomic_text(&path, &list.serialize()).map_err(|e| format!("{}: {e}", path.display()))
}

/// Reads `resourcePacks:[...]` from `options.txt` (bottom-first order, matching vanilla & Horizon).
/// Defaults to `["vanilla"]` when missing or unreadable.
pub fn read_resource_packs_option(options_path: &Path) -> Vec<String> {
    let Ok(text) = fs::read_to_string(options_path) else {
        return vec!["vanilla".to_owned()];
    };
    for line in text.lines() {
        let line = line.trim_end_matches('\r');
        if let Some(val) = line.strip_prefix("resourcePacks:")
            && let Ok(parsed) = serde_json::from_str::<Vec<String>>(val.trim())
        {
            if parsed.is_empty() {
                return vec!["vanilla".to_owned()];
            }
            return parsed;
        }
    }
    vec!["vanilla".to_owned()]
}

/// Updates ONLY `resourcePacks:[...]` in `options.txt` in-place while preserving ALL unrelated
/// lines, keys, keybinds, comments, and ordering verbatim.
pub fn write_resource_packs_option(options_path: &Path, packs: &[String]) -> Result<(), String> {
    let mut clean: Vec<String> = Vec::with_capacity(packs.len() + 1);
    if !packs.iter().any(|p| p == "vanilla") {
        clean.push("vanilla".to_owned());
    }
    for p in packs {
        if !p.is_empty() && !clean.contains(p) {
            clean.push(p.clone());
        }
    }
    let encoded = serde_json::to_string(&clean).map_err(|e| e.to_string())?;
    let mut lines: Vec<String> = Vec::new();
    let mut seen = false;

    if let Ok(existing) = fs::read_to_string(options_path) {
        for raw_line in existing.lines() {
            let line = raw_line.trim_end_matches('\r');
            if line.starts_with("resourcePacks:") {
                if !seen {
                    lines.push(format!("resourcePacks:{encoded}"));
                    seen = true;
                }
                continue;
            }
            lines.push(line.to_owned());
        }
    } else {
        lines.push(format!("version:{}", horizon_core::version::DATA_VERSION));
    }
    if !seen {
        lines.push(format!("resourcePacks:{encoded}"));
    }
    let mut body = lines.join("\n");
    body.push('\n');
    write_atomic_text(options_path, &body).map_err(|e| format!("{}: {e}", options_path.display()))
}

/// Enables or disables a pack in `Documents/resourcepacks/` via `Documents/options.txt`.
/// Newly enabled packs are placed at highest priority (end of bottom-first `resourcePacks` list).
pub fn set_resource_pack_enabled(
    game_dir: &Path,
    file_name: &str,
    enabled: bool,
) -> Result<(), String> {
    if !is_safe_filename(file_name) {
        return Err("Invalid resource pack filename".into());
    }
    let options_path = game_dir.join(OPTIONS_FILE);
    let mut packs = read_resource_packs_option(&options_path);
    if !packs.iter().any(|p| p == "vanilla") {
        packs.insert(0, "vanilla".to_owned());
    }
    let pack_id = format!("file/{file_name}");
    if enabled {
        if !packs.iter().any(|p| p == &pack_id) {
            packs.push(pack_id);
        }
    } else {
        packs.retain(|p| p != &pack_id);
    }
    write_resource_packs_option(&options_path, &packs)
}

/// Reorders an enabled resource pack in `Documents/options.txt`.
/// `move_up = true` raises priority (moves toward the end of the bottom-first `resourcePacks` list);
/// `move_up = false` lowers priority (moves toward the start, never moving below `"vanilla"`).
pub fn reorder_resource_pack(
    game_dir: &Path,
    file_name: &str,
    move_up: bool,
) -> Result<(), String> {
    if !is_safe_filename(file_name) {
        return Err("Invalid resource pack filename".into());
    }
    let options_path = game_dir.join(OPTIONS_FILE);
    let mut packs = read_resource_packs_option(&options_path);
    let pack_id = format!("file/{file_name}");
    let Some(pos) = packs.iter().position(|p| p == &pack_id) else {
        return Err("Resource pack is not enabled".into());
    };
    if move_up {
        if pos + 1 < packs.len() {
            packs.swap(pos, pos + 1);
        }
    } else if pos > 0 && packs[pos - 1] != "vanilla" {
        packs.swap(pos, pos - 1);
    }
    write_resource_packs_option(&options_path, &packs)
}

/// Reads `pickedShaderPack:` from `Documents/horizon-graphics.txt` (empty string when off).
pub fn read_picked_shader_pack(game_dir: &Path) -> String {
    let path = game_dir.join(GRAPHICS_FILE);
    let Ok(text) = fs::read_to_string(&path) else {
        return String::new();
    };
    for line in text.lines() {
        let line = line.trim_end_matches('\r');
        if let Some(val) = line.strip_prefix("pickedShaderPack:") {
            return val.trim().to_owned();
        }
    }
    String::new()
}

/// Updates ONLY `pickedShaderPack:<key>` in `Documents/horizon-graphics.txt` in-place while
/// preserving every other setting line verbatim. Pass `""` to disable shaders.
pub fn set_picked_shader_pack(game_dir: &Path, shader_key: &str) -> Result<(), String> {
    let clean = shader_key.trim();
    if clean.contains(['\n', '\r']) {
        return Err("Invalid shader key".into());
    }
    let path = game_dir.join(GRAPHICS_FILE);
    let mut lines: Vec<String> = Vec::new();
    let mut seen = false;
    if let Ok(existing) = fs::read_to_string(&path) {
        for raw_line in existing.lines() {
            let line = raw_line.trim_end_matches('\r');
            if line.starts_with("pickedShaderPack:") {
                if !seen {
                    lines.push(format!("pickedShaderPack:{clean}"));
                    seen = true;
                }
                continue;
            }
            lines.push(line.to_owned());
        }
    }
    if !seen {
        lines.push(format!("pickedShaderPack:{clean}"));
    }
    let mut body = lines.join("\n");
    body.push('\n');
    write_atomic_text(&path, &body).map_err(|e| format!("{}: {e}", path.display()))
}

fn read_datapacks_json(world_dir: &Path) -> (Vec<String>, Vec<String>) {
    let path = world_dir.join(DATAPACKS_FILE);
    let parsed: Option<Value> = fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok());
    let list = |key: &str| -> Vec<String> {
        parsed
            .as_ref()
            .and_then(|v| v[key].as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|s| s.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default()
    };
    (list("enabled"), list("disabled"))
}

fn write_datapacks_json(
    world_dir: &Path,
    enabled: &[String],
    disabled: &[String],
) -> Result<(), String> {
    let path = world_dir.join(DATAPACKS_FILE);
    let json = serde_json::json!({
        "enabled": enabled,
        "disabled": disabled,
    });
    let body = serde_json::to_string_pretty(&json).map_err(|e| e.to_string())?;
    write_atomic_text(&path, &body).map_err(|e| format!("{}: {e}", path.display()))
}

/// Enables or disables a data pack in `saves/<world>/datapacks.json` (1:1 with `datapack::enabled_ids`).
pub fn set_world_datapack_enabled(
    game_dir: &Path,
    world_folder: &str,
    file_name: &str,
    enabled: bool,
) -> Result<(), String> {
    if !is_safe_world_folder(world_folder) || !is_safe_filename(file_name) {
        return Err("Invalid world or data pack name".into());
    }
    let world_dir = game_dir.join("saves").join(world_folder);
    if !world_dir.is_dir() {
        return Err(format!("World not found: {world_folder}"));
    }
    let (mut en, mut dis) = read_datapacks_json(&world_dir);
    let pack_id = format!("file/{file_name}");
    if enabled {
        dis.retain(|id| id != &pack_id);
        if !en.iter().any(|id| id == "vanilla") && !dis.iter().any(|id| id == "vanilla") {
            en.insert(0, "vanilla".to_owned());
        }
        if !en.iter().any(|id| id == &pack_id) {
            en.push(pack_id);
        }
    } else {
        en.retain(|id| id != &pack_id);
        if !dis.iter().any(|id| id == &pack_id) {
            dis.push(pack_id);
        }
    }
    write_datapacks_json(&world_dir, &en, &dis)
}

fn forget_world_datapack(world_dir: &Path, file_name: &str) -> Result<(), String> {
    let path = world_dir.join(DATAPACKS_FILE);
    if !path.is_file() {
        return Ok(());
    }
    let (mut en, mut dis) = read_datapacks_json(world_dir);
    let pack_id = format!("file/{file_name}");
    let before = (en.len(), dis.len());
    en.retain(|id| id != &pack_id);
    dis.retain(|id| id != &pack_id);
    if (en.len(), dis.len()) != before {
        write_datapacks_json(world_dir, &en, &dis)?;
    }
    Ok(())
}

// ============================================================================
// Pack metadata helpers (pack.mcmeta, .hshader, .hmod)
// ============================================================================

fn extract_plain_mcmeta_text(val: &Value) -> String {
    let mut out = String::new();
    fn walk(v: &Value, out: &mut String) {
        match v {
            Value::String(s) => out.push_str(s),
            Value::Array(arr) => {
                for item in arr {
                    walk(item, out);
                }
            }
            Value::Object(map) => {
                if let Some(t) = map.get("text").and_then(Value::as_str) {
                    out.push_str(t);
                }
                if let Some(extra) = map.get("extra") {
                    walk(extra, out);
                }
            }
            _ => {}
        }
    }
    walk(val, &mut out);
    // Strip legacy § color codes.
    let mut clean = String::with_capacity(out.len());
    let mut chars = out.chars();
    while let Some(c) = chars.next() {
        if c == '§' {
            let _ = chars.next();
        } else {
            clean.push(c);
        }
    }
    clean.trim().to_owned()
}

fn read_pack_mcmeta_description(path: &Path) -> Option<String> {
    let raw = if path.is_dir() {
        fs::read(path.join("pack.mcmeta")).ok()?
    } else {
        let file = fs::File::open(path).ok()?;
        let mut zip = zip::ZipArchive::new(file).ok()?;
        let mut entry = zip.by_name("pack.mcmeta").ok()?;
        let mut buf = Vec::new();
        entry.by_ref().take(1 << 20).read_to_end(&mut buf).ok()?;
        buf
    };
    let json: Value = serde_json::from_slice(&raw).ok()?;
    let desc = extract_plain_mcmeta_text(&json["pack"]["description"]);
    Some(desc)
}

/// Validates a ZIP file as a resource pack (`pack.mcmeta` with `"pack"` object, plain paths).
pub fn validate_resource_pack_zip(path: &Path) -> Result<String, String> {
    let file = fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("Invalid ZIP archive: {e}"))?;
    for i in 0..zip.len() {
        let raw_name = zip
            .by_index_raw(i)
            .map_err(|e| format!("Corrupt ZIP entry: {e}"))?
            .name()
            .map_err(|e| format!("Corrupt ZIP entry name: {e}"))?
            .into_owned();
        if raw_name.starts_with('/')
            || raw_name.contains('\\')
            || raw_name.split('/').any(|p| p == "..")
        {
            return Err(format!("ZIP contains unsafe path: {raw_name:?}"));
        }
    }
    let mut meta = String::new();
    zip.by_name("pack.mcmeta")
        .map_err(|_| "Archive is missing pack.mcmeta".to_owned())?
        .take(1 << 20)
        .read_to_string(&mut meta)
        .map_err(|e| format!("Cannot read pack.mcmeta: {e}"))?;
    let json: Value =
        serde_json::from_str(&meta).map_err(|e| format!("Invalid pack.mcmeta JSON: {e}"))?;
    if !json["pack"].is_object() {
        return Err("pack.mcmeta is missing the \"pack\" object".into());
    }
    Ok(extract_plain_mcmeta_text(&json["pack"]["description"]))
}

/// Validates a ZIP file as a data pack (`pack.mcmeta` + `data/` root directory + plain paths).
pub fn validate_data_pack_zip(path: &Path) -> Result<String, String> {
    let file = fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("Invalid ZIP archive: {e}"))?;
    let mut has_data = false;
    for i in 0..zip.len() {
        let raw_name = zip
            .by_index_raw(i)
            .map_err(|e| format!("Corrupt ZIP entry: {e}"))?
            .name()
            .map_err(|e| format!("Corrupt ZIP entry name: {e}"))?
            .into_owned();
        if raw_name.starts_with('/')
            || raw_name.contains('\\')
            || raw_name.split('/').any(|p| p == "..")
        {
            return Err(format!("ZIP contains unsafe path: {raw_name:?}"));
        }
        if raw_name.starts_with("data/") {
            has_data = true;
        }
    }
    if !has_data {
        return Err("Archive has no data/ folder (not a data pack)".into());
    }
    let mut meta = String::new();
    zip.by_name("pack.mcmeta")
        .map_err(|_| "Archive is missing pack.mcmeta".to_owned())?
        .take(1 << 20)
        .read_to_string(&mut meta)
        .map_err(|e| format!("Cannot read pack.mcmeta: {e}"))?;
    let json: Value =
        serde_json::from_str(&meta).map_err(|e| format!("Invalid pack.mcmeta JSON: {e}"))?;
    if !json["pack"].is_object() {
        return Err("pack.mcmeta is missing the \"pack\" object".into());
    }
    Ok(extract_plain_mcmeta_text(&json["pack"]["description"]))
}

/// Computes the exact shader key that Horizon's `shader_pack_list::scan` uses.
pub fn shader_key_for_path(path: &Path) -> (String, String, bool, bool) {
    let file = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or_default()
        .to_owned();
    if horizon_shader_api::package::is_pack(path) {
        if let Ok(manifest) = horizon_shader_api::Pack::read_manifest(path) {
            let traces = manifest.ray_tracing.is_some();
            return (format!("horizon:{}", manifest.id), manifest.name, true, traces);
        }
        if let Some(id) = horizon_shader_api::Pack::declared_id(path) {
            return (format!("horizon:{id}"), file, true, false);
        }
        return (file.clone(), file, true, false);
    }
    (file.clone(), file, false, false)
}

// ============================================================================
// Persistent tracking manifest: Documents/mod-browser.json
// ============================================================================

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InstalledRecord {
    pub source: String,
    pub project_id: String,
    pub slug: String,
    pub name: String,
    pub kind: String,
    pub version_id: String,
    pub version_number: String,
    /// Relative to game dir (e.g. `horizon-mods/zoom.hmod`, `resourcepacks/pack.zip`,
    /// `shaderpacks/vivid.hshader`, `saves/<world>/datapacks/dp.zip`).
    pub file: String,
    /// `<ALGO>:<hex>`, e.g. `SHA-256:...` or `SHA-512:...`.
    pub checksum: String,
    #[serde(default)]
    pub icon_url: String,
    #[serde(default)]
    pub world: String,
    #[serde(default)]
    pub is_wasm: bool,
    #[serde(default)]
    pub heavy_gpu: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BrowserManifest {
    #[serde(default)]
    pub entries: Vec<InstalledRecord>,
}

/// Verifies `rel` stays inside one of the managed folders (no `..`, no absolute paths).
pub fn is_managed_rel_path(rel: &str) -> bool {
    let mut comps = Path::new(rel).components();
    let Some(Component::Normal(first)) = comps.next() else {
        return false;
    };
    let rest: Vec<Component<'_>> = comps.collect();
    if rest.is_empty() || !rest.iter().all(|c| matches!(c, Component::Normal(_))) {
        return false;
    }
    match first.to_str() {
        Some("horizon-mods" | "resourcepacks" | "shaderpacks") => rest.len() == 1,
        Some("saves") => {
            rest.len() == 3
                && matches!(rest[1], Component::Normal(s) if s == "datapacks")
        }
        _ => false,
    }
}

impl BrowserManifest {
    pub fn load(game_dir: &Path) -> Self {
        let Ok(text) = fs::read_to_string(game_dir.join(MANIFEST_FILE)) else {
            return Self::default();
        };
        let Ok(mut parsed) = serde_json::from_str::<Self>(&text) else {
            return Self::default();
        };
        parsed.entries.retain(|e| is_managed_rel_path(&e.file));
        parsed
    }

    pub fn save(&self, game_dir: &Path) -> Result<(), String> {
        let path = game_dir.join(MANIFEST_FILE);
        let text = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        write_atomic_text(&path, &text).map_err(|e| format!("{}: {e}", path.display()))
    }

    pub fn find(&self, source: &str, project_id: &str, world: &str) -> Option<&InstalledRecord> {
        self.entries.iter().find(|e| {
            e.source == source
                && e.project_id == project_id
                && (e.kind != "datapack" || e.world == world)
        })
    }

    pub fn upsert(&mut self, record: InstalledRecord) {
        self.entries.retain(|e| {
            !(e.source == record.source
                && e.project_id == record.project_id
                && (e.kind != "datapack" || e.world == record.world))
        });
        self.entries.push(record);
    }
}

// ============================================================================
// Horizon Registry Index loading & parsing
// ============================================================================

fn index_cache_path(game_dir: &Path) -> PathBuf {
    game_dir.join(INDEX_CACHE_REL)
}

/// Loads the Horizon Registry index with in-memory + disk caching (TTL 10 min) and offline fallback.
/// Returns `(Index, offline_fallback)`.
pub fn load_horizon_index(game_dir: &Path, force_refresh: bool) -> Result<(Index, bool), String> {
    let key = game_dir.to_path_buf();
    if !force_refresh
        && let Ok(guard) = INDEX_MEM_CACHE.lock()
        && let Some((at, idx)) = guard.get(&key)
        && at.elapsed() < INDEX_TTL
    {
        return Ok((idx.clone(), false));
    }

    let cache_path = index_cache_path(game_dir);
    if !force_refresh
        && let Ok(meta) = fs::metadata(&cache_path)
        && let Ok(modified) = meta.modified()
        && modified.elapsed().is_ok_and(|age| age < INDEX_TTL)
        && let Ok(text) = fs::read_to_string(&cache_path)
        && let Ok(idx) = Index::parse(&text)
    {
        if let Ok(mut guard) = INDEX_MEM_CACHE.lock() {
            guard.insert(key, (Instant::now(), idx.clone()));
        }
        return Ok((idx, false));
    }

    match fetch_horizon_index_network() {
        Ok((idx, raw)) => {
            if let Some(parent) = cache_path.parent() {
                let _ = fs::create_dir_all(parent);
            }
            let _ = write_atomic_text(&cache_path, &raw);
            if let Ok(mut guard) = INDEX_MEM_CACHE.lock() {
                guard.insert(key, (Instant::now(), idx.clone()));
            }
            Ok((idx, false))
        }
        Err(net_err) => {
            if let Ok(kept) = fs::read_to_string(&cache_path)
                && let Ok(idx) = Index::parse(&kept)
            {
                if let Ok(mut guard) = INDEX_MEM_CACHE.lock() {
                    guard.insert(key, (Instant::now(), idx.clone()));
                }
                return Ok((idx, true));
            }
            Err(net_err)
        }
    }
}

fn fetch_horizon_index_network() -> Result<(Index, String), String> {
    let response = http_agent()
        .get(HORIZON_INDEX_URL)
        .call()
        .map_err(|e| match e {
            ureq::Error::Status(code, _) => format!("Horizon Registry returned HTTP {code}"),
            ureq::Error::Transport(t) => format!("Cannot reach Horizon Registry: {t}"),
        })?;
    let mut raw = String::new();
    response
        .into_reader()
        .take(MAX_INDEX_BYTES)
        .read_to_string(&mut raw)
        .map_err(|e| format!("Failed reading Horizon Registry: {e}"))?;
    let idx = Index::parse(&raw)?;
    Ok((idx, raw))
}

fn horizon_is_wasm_hint(p: &index::Project) -> bool {
    if p.kind != index::Kind::Mod {
        return false;
    }
    if p.tags
        .iter()
        .any(|t| matches!(t.as_str(), "wasm" | "webassembly"))
    {
        return true;
    }
    let hay = format!(
        "{} {} {}",
        p.summary,
        p.description,
        p.versions
            .first()
            .map_or("", |v| v.changelog.as_str())
    )
    .to_ascii_lowercase();
    hay.contains("webassembly")
        || hay.contains("wasm")
        || hay.contains("api only: no injections")
}

fn horizon_is_heavy_gpu(p: &index::Project) -> bool {
    if !matches!(p.kind, index::Kind::Shader | index::Kind::ShaderPack) {
        return false;
    }
    let hay = format!(
        "{} {} {} {} {}",
        p.id,
        p.name,
        p.summary,
        p.categories.join(" "),
        p.tags.join(" ")
    )
    .to_ascii_lowercase();
    for needle in [
        "raytracing",
        "ray-tracing",
        "ray tracing",
        "ray-traced",
        "path-tracing",
        "pathtracing",
        "ptgi",
        "rtx",
        "screenshot",
    ] {
        if hay.contains(needle) {
            return true;
        }
    }
    p.categories.iter().any(|c| c == "path-tracing" || c == "high")
        || p.description.to_ascii_lowercase().contains("hardware ray")
}

fn horizon_is_official(p: &index::Project) -> bool {
    p.authors == ["Horizon"] && p.source.starts_with("https://github.com/horizon-rust/")
}

fn horizon_kind_str(kind: &index::Kind) -> Option<&'static str> {
    match kind {
        index::Kind::Mod | index::Kind::NativeMod => Some("mod"),
        index::Kind::ResourcePack => Some("resourcepack"),
        index::Kind::Shader | index::Kind::ShaderPack => Some("shader"),
        index::Kind::DataPack => Some("datapack"),
        index::Kind::Modpack | index::Kind::Other(_) => None,
    }
}

fn horizon_capabilities_list(v: &index::Version) -> Vec<String> {
    let mut caps: Vec<String> = v
        .capabilities
        .known()
        .iter()
        .map(|c| c.describe().to_owned())
        .collect();
    for unk in v.capabilities.unknown() {
        caps.push(format!("unsupported:{unk}"));
    }
    caps
}

fn horizon_blocked_reason(index: &Index, p: &index::Project) -> Option<String> {
    if p.kind == index::Kind::NativeMod {
        return Some("Desktop only (native Rust mod)".into());
    }
    let for_game: Vec<&index::Version> = p.versions.iter().filter(|v| v.game == GAME_VERSION).collect();
    if for_game.is_empty() {
        return Some(format!("No version for Minecraft {GAME_VERSION}"));
    }
    if index.installable(p, GAME_VERSION).is_some() {
        return None;
    }
    if let Some(r) = for_game
        .iter()
        .find_map(|v| index.revoked(&p.id, &v.file.sha256))
    {
        return Some(format!("Taken down: {}", r.reason));
    }
    if p.kind == index::Kind::Shader
        && for_game.iter().all(|v| v.api != horizon_shader_api::API)
    {
        return Some(format!(
            "Needs shader API {} (this build serves {})",
            for_game[0].api,
            horizon_shader_api::API
        ));
    }
    if let Some(msg) = for_game.iter().find_map(|v| v.capabilities.unsupported()) {
        return Some(msg);
    }
    Some("Not compatible with this build".into())
}

// ============================================================================
// Catalog Search & Details API (Horizon Registry + Modrinth v2)
// ============================================================================

#[derive(Clone, Debug, Default, Deserialize)]
pub struct SearchRequest {
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub query: String,
    #[serde(default)]
    pub category: String,
    #[serde(default)]
    pub sort: String,
    #[serde(default)]
    pub offset: usize,
    #[serde(default)]
    pub limit: usize,
    #[serde(default)]
    pub show_desktop_only: bool,
    #[serde(default)]
    pub all_versions: bool,
    #[serde(default)]
    pub force_refresh: bool,
    #[serde(default)]
    pub world: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogItem {
    pub source: String,
    pub id: String,
    pub slug: String,
    pub name: String,
    pub summary: String,
    pub author: String,
    pub kind: String,
    pub downloads: u64,
    pub icon_url: String,
    pub license: String,
    pub version: String,
    pub file_size: u64,
    pub game_compat: String,
    pub is_wasm: bool,
    pub desktop_only: bool,
    pub heavy_gpu: bool,
    pub official: bool,
    pub signed: bool,
    pub installable: bool,
    pub blocked_reason: String,
    pub capabilities: Vec<String>,
    pub categories: Vec<String>,
    pub installed: bool,
    pub installed_version: String,
    pub update_available: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SearchResponse {
    pub ok: bool,
    pub items: Vec<CatalogItem>,
    pub total: usize,
    pub categories: Vec<String>,
    pub offline: bool,
    pub banner: String,
    pub error: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProjectDetails {
    pub source: String,
    pub id: String,
    pub slug: String,
    pub name: String,
    pub summary: String,
    pub description: String,
    pub author: String,
    pub kind: String,
    pub downloads: u64,
    pub icon_url: String,
    pub license: String,
    pub version_id: String,
    pub version: String,
    pub published: String,
    pub filename: String,
    pub file_size: u64,
    pub checksum_note: String,
    pub source_url: String,
    pub page_url: String,
    pub game_compat: String,
    pub is_wasm: bool,
    pub desktop_only: bool,
    pub heavy_gpu: bool,
    pub official: bool,
    pub signed: bool,
    pub installable: bool,
    pub blocked_reason: String,
    pub revoked_reason: String,
    pub capabilities: Vec<String>,
    pub categories: Vec<String>,
    pub installed: bool,
    pub installed_version: String,
    pub update_available: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DetailsResponse {
    pub ok: bool,
    pub details: Option<ProjectDetails>,
    pub error: String,
}

fn horizon_categories_for_kind(kind: &str) -> Vec<String> {
    let k = match kind {
        "mod" => index::Kind::Mod,
        "resourcepack" => index::Kind::ResourcePack,
        "shader" => index::Kind::Shader,
        "datapack" => index::Kind::DataPack,
        _ => return Vec::new(),
    };
    index::page::categories(&k)
        .iter()
        .map(|s| (*s).to_owned())
        .collect()
}

/// Filters and ranks projects from a parsed Horizon Registry `Index` (pure function, easy to test).
pub fn search_horizon_index(
    index: &Index,
    manifest: &BrowserManifest,
    req: &SearchRequest,
) -> (Vec<CatalogItem>, usize) {
    let kind = if req.kind.is_empty() {
        "mod"
    } else {
        req.kind.as_str()
    };
    let query_words: Vec<String> = req
        .query
        .split_whitespace()
        .map(|w| w.to_ascii_lowercase())
        .collect();
    let cat = req.category.trim().to_ascii_lowercase();

    let mut matched: Vec<&index::Project> = index
        .projects
        .iter()
        .filter(|p| horizon_kind_str(&p.kind) == Some(kind))
        .filter(|p| req.show_desktop_only || p.kind != index::Kind::NativeMod)
        .filter(|p| {
            if cat.is_empty() {
                true
            } else {
                p.categories
                    .iter()
                    .any(|c| c.eq_ignore_ascii_case(&cat))
            }
        })
        .filter(|p| {
            if query_words.is_empty() {
                return true;
            }
            let hay = format!(
                "{} {} {} {} {}",
                p.id,
                p.name,
                p.summary,
                p.authors.join(" "),
                p.tags.join(" ")
            )
            .to_ascii_lowercase();
            query_words.iter().all(|w| hay.contains(w))
        })
        .collect();

    let day = |p: &index::Project, newest: bool| -> String {
        let iter = p.versions.iter().map(|v| v.published.as_str());
        let picked = if newest { iter.min() } else { iter.max() };
        picked.unwrap_or("").to_owned()
    };

    match req.sort.as_str() {
        "newest" => matched.sort_by_cached_key(|p| {
            (
                p.kind == index::Kind::NativeMod,
                std::cmp::Reverse(day(p, true)),
                std::cmp::Reverse(p.downloads),
            )
        }),
        "updated" => matched.sort_by_cached_key(|p| {
            (
                p.kind == index::Kind::NativeMod,
                std::cmp::Reverse(day(p, false)),
                std::cmp::Reverse(p.downloads),
            )
        }),
        _ => matched.sort_by_key(|p| {
            (
                p.kind == index::Kind::NativeMod,
                std::cmp::Reverse(p.downloads),
            )
        }),
    }

    let mut items: Vec<CatalogItem> = matched
        .into_iter()
        .map(|p| build_horizon_catalog_item(index, manifest, p, &req.world))
        .collect();

    // Put installable items ahead of blocked/desktop-only items while keeping sort order inside each bucket.
    items.sort_by_key(|item| (!item.installable, item.desktop_only));

    let total = items.len();
    let limit = if req.limit == 0 { 40 } else { req.limit.min(100) };
    let page = items.into_iter().skip(req.offset).take(limit).collect();
    (page, total)
}

fn build_horizon_catalog_item(
    index: &Index,
    manifest: &BrowserManifest,
    p: &index::Project,
    world: &str,
) -> CatalogItem {
    let kind_str = horizon_kind_str(&p.kind).unwrap_or("mod").to_owned();
    let desktop_only = p.kind == index::Kind::NativeMod;
    let inst_ver = if desktop_only {
        None
    } else {
        index.installable(p, GAME_VERSION)
    };
    let latest_ver = inst_ver.or_else(|| p.versions.first());
    let blocked_reason = horizon_blocked_reason(index, p).unwrap_or_default();
    let installable = !desktop_only && inst_ver.is_some() && blocked_reason.is_empty();
    let existing = manifest.find("horizon", &p.id, world);
    let version = latest_ver.map_or_else(String::new, |v| v.version.clone());
    let update_available = existing
        .zip(inst_ver)
        .is_some_and(|(e, v)| e.version_id != v.version);

    let game_compat = if p.versions.iter().any(|v| v.game == GAME_VERSION) {
        GAME_VERSION.to_owned()
    } else {
        latest_ver.map_or_else(String::new, |v| v.game.clone())
    };

    CatalogItem {
        source: "horizon".into(),
        id: p.id.clone(),
        slug: p.id.clone(),
        name: p.name.clone(),
        summary: p.summary.clone(),
        author: p.authors.join(", "),
        kind: kind_str,
        downloads: p.downloads,
        icon_url: p.icon.clone().unwrap_or_default(),
        license: p.license.clone(),
        version,
        file_size: latest_ver.map_or(0, |v| v.file.size),
        game_compat,
        is_wasm: horizon_is_wasm_hint(p),
        desktop_only,
        heavy_gpu: horizon_is_heavy_gpu(p),
        official: horizon_is_official(p),
        signed: p.key.is_some(),
        installable,
        blocked_reason,
        capabilities: latest_ver
            .filter(|_| p.kind == index::Kind::Mod)
            .map(horizon_capabilities_list)
            .unwrap_or_default(),
        categories: p.categories.clone(),
        installed: existing.is_some(),
        installed_version: existing.map_or_else(String::new, |e| e.version_number.clone()),
        update_available,
    }
}

fn percent_encode(s: &str) -> String {
    prelauncher::percent_encode_query_value(s)
}

fn modrinth_compat_label(versions: &[String]) -> String {
    if versions.iter().any(|v| v == GAME_VERSION) {
        return GAME_VERSION.to_owned();
    }
    if versions.iter().any(|v| v.starts_with("26.")) {
        return "26.x".to_owned();
    }
    if versions.iter().any(|v| v.starts_with("1.21")) {
        return "1.21+".to_owned();
    }
    "other".to_owned()
}

fn is_compatible_mc_version(v: &str) -> bool {
    v == GAME_VERSION || v.starts_with("26.") || v.starts_with("1.21")
}

/// Parses a Modrinth `/v2/search` JSON response into `CatalogItem`s.
pub fn parse_modrinth_search_response(
    json: &Value,
    kind: &str,
    manifest: &BrowserManifest,
    world: &str,
) -> (Vec<CatalogItem>, usize) {
    let total = json["total_hits"].as_u64().unwrap_or(0) as usize;
    let items = json["hits"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|hit| {
            let id = hit["project_id"].as_str()?.to_owned();
            let slug = hit["slug"].as_str().unwrap_or(&id).to_owned();
            let name = hit["title"].as_str().unwrap_or(&slug).to_owned();
            let summary = hit["description"].as_str().unwrap_or("").to_owned();
            let author = hit["author"].as_str().unwrap_or("").to_owned();
            let downloads = hit["downloads"].as_u64().unwrap_or(0);
            let icon_url = hit["icon_url"].as_str().unwrap_or("").to_owned();
            let license = hit["license"].as_str().unwrap_or("").to_owned();
            let versions: Vec<String> = hit["versions"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect();
            let categories: Vec<String> = hit["categories"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect();
            let existing = manifest.find("modrinth", &id, world);
            let game_compat = modrinth_compat_label(&versions);
            Some(CatalogItem {
                source: "modrinth".into(),
                id,
                slug,
                name,
                summary,
                author,
                kind: kind.to_owned(),
                downloads,
                icon_url,
                license,
                version: hit["latest_version"].as_str().unwrap_or("").to_owned(),
                file_size: 0,
                game_compat,
                is_wasm: false,
                desktop_only: false,
                heavy_gpu: false,
                official: false,
                signed: false,
                installable: true,
                blocked_reason: String::new(),
                capabilities: Vec::new(),
                categories,
                installed: existing.is_some(),
                installed_version: existing.map_or_else(String::new, |e| e.version_number.clone()),
                update_available: false,
            })
        })
        .collect();
    (items, total)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModrinthVersionFile {
    pub version_id: String,
    pub version_number: String,
    pub published: String,
    pub game_versions: Vec<String>,
    pub loaders: Vec<String>,
    pub filename: String,
    pub url: String,
    pub size: u64,
    pub sha512: String,
}

/// Parses a Modrinth `/v2/project/{id}/version` JSON array and picks the newest compatible file
/// for `kind` (`"resourcepack"` or `"datapack"`).
pub fn pick_modrinth_version_file(
    versions_json: &Value,
    kind: &str,
    allow_older: bool,
) -> Option<ModrinthVersionFile> {
    let mut candidates: Vec<ModrinthVersionFile> = versions_json
        .as_array()?
        .iter()
        .filter(|v| v["status"].as_str().is_none_or(|s| s == "listed"))
        .filter_map(|v| {
            let version_id = v["id"].as_str()?.to_owned();
            let version_number = v["version_number"]
                .as_str()
                .unwrap_or(&version_id)
                .to_owned();
            let published = v["date_published"].as_str().unwrap_or("").to_owned();
            let game_versions: Vec<String> = v["game_versions"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|s| s.as_str().map(str::to_owned))
                .collect();
            let loaders: Vec<String> = v["loaders"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|s| s.as_str().map(str::to_owned))
                .collect();
            if kind == "datapack" && !loaders.iter().any(|l| l == "datapack") {
                return None;
            }
            let files = v["files"].as_array()?;
            // Prefer primary .zip file with SHA-512 hash; fallback to any .zip with SHA-512.
            let chosen = files
                .iter()
                .find(|f| {
                    f["primary"].as_bool().unwrap_or(false)
                        && f["filename"]
                            .as_str()
                            .is_some_and(|n| n.to_ascii_lowercase().ends_with(".zip"))
                        && f["hashes"]["sha512"].as_str().is_some()
                })
                .or_else(|| {
                    files.iter().find(|f| {
                        f["filename"]
                            .as_str()
                            .is_some_and(|n| n.to_ascii_lowercase().ends_with(".zip"))
                            && f["hashes"]["sha512"].as_str().is_some()
                    })
                })?;
            let filename = chosen["filename"].as_str()?.to_owned();
            let url = chosen["url"].as_str()?.to_owned();
            let size = chosen["size"].as_u64().unwrap_or(0);
            let sha512 = chosen["hashes"]["sha512"]
                .as_str()?
                .to_ascii_lowercase();
            Some(ModrinthVersionFile {
                version_id,
                version_number,
                published,
                game_versions,
                loaders,
                filename,
                url,
                size,
                sha512,
            })
        })
        .collect();

    // Sort newest first by ISO 8601 published timestamp.
    candidates.sort_by(|a, b| b.published.cmp(&a.published));

    // Prefer exact 26.3, then 26.x, then 1.21+, then any (when allow_older).
    candidates
        .iter()
        .find(|c| c.game_versions.iter().any(|g| g == GAME_VERSION))
        .or_else(|| {
            candidates
                .iter()
                .find(|c| c.game_versions.iter().any(|g| g.starts_with("26.")))
        })
        .or_else(|| {
            candidates
                .iter()
                .find(|c| c.game_versions.iter().any(|g| is_compatible_mc_version(g)))
        })
        .or_else(|| allow_older.then(|| candidates.first()).flatten())
        .cloned()
}

fn modrinth_get_json(url: &str) -> Result<Value, String> {
    let response = http_agent().get(url).call().map_err(|e| match e {
        ureq::Error::Status(429, _) => {
            "Modrinth rate limit reached: please wait a moment and try again".into()
        }
        ureq::Error::Status(code, _) => format!("Modrinth returned HTTP {code}"),
        ureq::Error::Transport(t) => format!("Cannot reach Modrinth: {t}"),
    })?;
    let mut raw = String::new();
    response
        .into_reader()
        .take(MAX_INDEX_BYTES)
        .read_to_string(&mut raw)
        .map_err(|e| format!("Failed reading Modrinth response: {e}"))?;
    serde_json::from_str(&raw).map_err(|e| format!("Invalid Modrinth JSON: {e}"))
}

/// Executes a catalog search against Horizon Registry or Modrinth v2.
pub fn search_catalog(game_dir: &Path, req: &SearchRequest) -> SearchResponse {
    let kind = if req.kind.is_empty() {
        "mod"
    } else {
        req.kind.as_str()
    };
    let source = if req.source.is_empty() {
        "horizon"
    } else {
        req.source.as_str()
    };

    // Shaders are Horizon Registry only (matching desktop launcher & docs/mod-browser.md).
    if kind == "shader" && source != "horizon" {
        return SearchResponse {
            ok: true,
            items: Vec::new(),
            total: 0,
            categories: horizon_categories_for_kind("shader"),
            offline: false,
            banner: "Shaders are provided via Horizon Registry only.".into(),
            error: String::new(),
        };
    }

    // Mods on Modrinth: clear banner explaining Stage 1 (Horizon Registry .hmod + WASM) vs Stage 2 (Java porting).
    if kind == "mod" && source == "modrinth" {
        return SearchResponse {
            ok: true,
            items: Vec::new(),
            total: 0,
            categories: Vec::new(),
            offline: false,
            banner: "Horizon .hmod & WASM (Pulley64) mods are available in Horizon Registry. Automatic Java mod porting from Modrinth is planned for Stage 2.".into(),
            error: String::new(),
        };
    }

    let manifest = BrowserManifest::load(game_dir);

    if source == "horizon" {
        match load_horizon_index(game_dir, req.force_refresh) {
            Ok((idx, offline)) => {
                let (items, total) = search_horizon_index(&idx, &manifest, req);
                let banner = if offline {
                    "Offline mode: showing cached Horizon Registry index.".into()
                } else {
                    String::new()
                };
                SearchResponse {
                    ok: true,
                    items,
                    total,
                    categories: horizon_categories_for_kind(kind),
                    offline,
                    banner,
                    error: String::new(),
                }
            }
            Err(err) => SearchResponse {
                ok: false,
                items: Vec::new(),
                total: 0,
                categories: horizon_categories_for_kind(kind),
                offline: false,
                banner: String::new(),
                error: err,
            },
        }
    } else if source == "modrinth" {
        let project_type = match kind {
            "resourcepack" => "resourcepack",
            "datapack" => "datapack",
            _ => {
                return SearchResponse {
                    ok: false,
                    items: Vec::new(),
                    total: 0,
                    categories: Vec::new(),
                    offline: false,
                    banner: String::new(),
                    error: format!("Unsupported Modrinth kind: {kind}"),
                };
            }
        };
        let mut facets: Vec<Vec<String>> = vec![vec![format!("project_type:{project_type}")]];
        if !req.all_versions {
            facets.push(vec![format!("versions:{GAME_VERSION}")]);
        }
        if !req.category.trim().is_empty() {
            facets.push(vec![format!("categories:{}", req.category.trim())]);
        }
        let facets_json = serde_json::to_string(&facets).unwrap_or_default();
        let sort = match req.sort.as_str() {
            "downloads" => "downloads",
            "newest" => "newest",
            "updated" => "updated",
            "relevance" => "relevance",
            _ => {
                if req.query.trim().is_empty() {
                    "downloads"
                } else {
                    "relevance"
                }
            }
        };
        let limit = if req.limit == 0 { 25 } else { req.limit.min(50) };
        let mut url = format!(
            "{MODRINTH_API_URL}/search?facets={}&index={sort}&offset={}&limit={limit}",
            percent_encode(&facets_json),
            req.offset,
        );
        if !req.query.trim().is_empty() {
            url.push_str("&query=");
            url.push_str(&percent_encode(req.query.trim()));
        }
        let categories: Vec<String> = match kind {
            "resourcepack" => MODRINTH_RP_CATEGORIES
                .iter()
                .map(|s| (*s).to_owned())
                .collect(),
            "datapack" => MODRINTH_DP_CATEGORIES
                .iter()
                .map(|s| (*s).to_owned())
                .collect(),
            _ => Vec::new(),
        };
        match modrinth_get_json(&url) {
            Ok(json) => {
                let (items, total) =
                    parse_modrinth_search_response(&json, kind, &manifest, &req.world);
                SearchResponse {
                    ok: true,
                    items,
                    total,
                    categories,
                    offline: false,
                    banner: String::new(),
                    error: String::new(),
                }
            }
            Err(err) => SearchResponse {
                ok: false,
                items: Vec::new(),
                total: 0,
                categories,
                offline: false,
                banner: String::new(),
                error: err,
            },
        }
    } else {
        SearchResponse {
            ok: false,
            items: Vec::new(),
            total: 0,
            categories: Vec::new(),
            offline: false,
            banner: String::new(),
            error: format!("Unknown source: {source}"),
        }
    }
}

/// Fetches full project details (for the detail modal sheet).
pub fn fetch_project_details(
    game_dir: &Path,
    source: &str,
    project_id: &str,
    kind: &str,
    world: &str,
) -> DetailsResponse {
    let manifest = BrowserManifest::load(game_dir);
    if source == "horizon" {
        let (idx, _) = match load_horizon_index(game_dir, false) {
            Ok(v) => v,
            Err(e) => {
                return DetailsResponse {
                    ok: false,
                    details: None,
                    error: e,
                };
            }
        };
        let Some(p) = idx.project(project_id) else {
            return DetailsResponse {
                ok: false,
                details: None,
                error: format!("Project {project_id} not found in Horizon Registry"),
            };
        };
        let item = build_horizon_catalog_item(&idx, &manifest, p, world);
        let inst_ver = if item.desktop_only {
            None
        } else {
            idx.installable(p, GAME_VERSION)
        };
        let latest = inst_ver.or_else(|| p.versions.first());
        let revoked_reason = latest
            .and_then(|v| idx.revoked(&p.id, &v.file.sha256))
            .map(|r| r.reason.clone())
            .unwrap_or_default();
        let checksum_note = latest.map_or_else(String::new, |v| {
            let short = v.file.sha256.get(..16).unwrap_or(&v.file.sha256);
            if p.key.is_some() {
                format!("SHA-256 ({short}…) + author minisign signature verified")
            } else {
                format!("SHA-256 ({short}…) verified against Horizon Registry")
            }
        });
        let details = ProjectDetails {
            source: "horizon".into(),
            id: p.id.clone(),
            slug: p.id.clone(),
            name: p.name.clone(),
            summary: p.summary.clone(),
            description: if p.description.trim().is_empty() {
                p.summary.clone()
            } else {
                p.description.clone()
            },
            author: p.authors.join(", "),
            kind: item.kind,
            downloads: p.downloads,
            icon_url: p.icon.clone().unwrap_or_default(),
            license: p.license.clone(),
            version_id: latest.map_or_else(String::new, |v| v.version.clone()),
            version: latest.map_or_else(String::new, |v| v.version.clone()),
            published: latest.map_or_else(String::new, |v| v.published.clone()),
            filename: latest.map_or_else(String::new, |v| v.file.name.clone()),
            file_size: latest.map_or(0, |v| v.file.size),
            checksum_note,
            source_url: p.source.clone(),
            page_url: format!("{HORIZON_SITE_URL}/{}", p.id),
            game_compat: item.game_compat,
            is_wasm: item.is_wasm,
            desktop_only: item.desktop_only,
            heavy_gpu: item.heavy_gpu,
            official: item.official,
            signed: item.signed,
            installable: item.installable,
            blocked_reason: item.blocked_reason,
            revoked_reason,
            capabilities: item.capabilities,
            categories: p.categories.clone(),
            installed: item.installed,
            installed_version: item.installed_version,
            update_available: item.update_available,
        };
        DetailsResponse {
            ok: true,
            details: Some(details),
            error: String::new(),
        }
    } else if source == "modrinth" {
        let proj_url = format!("{MODRINTH_API_URL}/project/{}", percent_encode(project_id));
        let proj = match modrinth_get_json(&proj_url) {
            Ok(v) => v,
            Err(e) => {
                return DetailsResponse {
                    ok: false,
                    details: None,
                    error: e,
                };
            }
        };
        let vers_url = format!(
            "{MODRINTH_API_URL}/project/{}/version",
            percent_encode(project_id)
        );
        let vers = modrinth_get_json(&vers_url).unwrap_or(Value::Array(Vec::new()));
        let chosen = pick_modrinth_version_file(&vers, kind, true);

        let id = proj["id"].as_str().unwrap_or(project_id).to_owned();
        let slug = proj["slug"].as_str().unwrap_or(&id).to_owned();
        let name = proj["title"].as_str().unwrap_or(&slug).to_owned();
        let summary = proj["description"].as_str().unwrap_or("").to_owned();
        let body = proj["body"].as_str().unwrap_or("").to_owned();
        let license = proj["license"]["id"]
            .as_str()
            .or_else(|| proj["license"]["name"].as_str())
            .unwrap_or("")
            .to_owned();
        let game_versions: Vec<String> = proj["game_versions"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect();
        let categories: Vec<String> = proj["categories"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect();
        let existing = manifest.find("modrinth", &id, world);
        let update_available = existing
            .zip(chosen.as_ref())
            .is_some_and(|(e, v)| e.version_id != v.version_id);
        let checksum_note = chosen.as_ref().map_or_else(String::new, |v| {
            let short = v.sha512.get(..16).unwrap_or(&v.sha512);
            format!("SHA-512 ({short}…) verified from Modrinth")
        });
        let ptype = match kind {
            "datapack" => "datapack",
            _ => "resourcepack",
        };
        let details = ProjectDetails {
            source: "modrinth".into(),
            id: id.clone(),
            slug: slug.clone(),
            name,
            summary: summary.clone(),
            description: if body.trim().is_empty() {
                summary
            } else {
                body
            },
            author: String::new(),
            kind: kind.to_owned(),
            downloads: proj["downloads"].as_u64().unwrap_or(0),
            icon_url: proj["icon_url"].as_str().unwrap_or("").to_owned(),
            license,
            version_id: chosen
                .as_ref()
                .map_or_else(String::new, |v| v.version_id.clone()),
            version: chosen
                .as_ref()
                .map_or_else(String::new, |v| v.version_number.clone()),
            published: chosen
                .as_ref()
                .map_or_else(String::new, |v| v.published.clone()),
            filename: chosen
                .as_ref()
                .map_or_else(String::new, |v| v.filename.clone()),
            file_size: chosen.as_ref().map_or(0, |v| v.size),
            checksum_note,
            source_url: proj["source_url"].as_str().unwrap_or("").to_owned(),
            page_url: format!("{MODRINTH_SITE_URL}/{ptype}/{slug}"),
            game_compat: modrinth_compat_label(&game_versions),
            is_wasm: false,
            desktop_only: false,
            heavy_gpu: false,
            official: false,
            signed: false,
            installable: chosen.is_some(),
            blocked_reason: if chosen.is_none() {
                "No compatible .zip file found on Modrinth".into()
            } else {
                String::new()
            },
            revoked_reason: String::new(),
            capabilities: Vec::new(),
            categories,
            installed: existing.is_some(),
            installed_version: existing.map_or_else(String::new, |e| e.version_number.clone()),
            update_available,
        };
        DetailsResponse {
            ok: true,
            details: Some(details),
            error: String::new(),
        }
    } else {
        DetailsResponse {
            ok: false,
            details: None,
            error: format!("Unknown source: {source}"),
        }
    }
}

// ============================================================================
// Install, Update, Remove
// ============================================================================

#[derive(Clone, Debug, Default, Deserialize)]
pub struct InstallRequest {
    pub source: String,
    pub project_id: String,
    pub kind: String,
    #[serde(default)]
    pub world: String,
    #[serde(default)]
    pub allow_older: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InstallResponse {
    pub ok: bool,
    pub installed: Option<InstalledRecord>,
    pub error: String,
}

fn staging_dir(game_dir: &Path) -> PathBuf {
    game_dir.join("mod-browser").join("downloads")
}

/// Installs (or updates) one project from Horizon Registry or Modrinth into `game_dir`.
pub fn install_project(game_dir: &Path, req: &InstallRequest) -> InstallResponse {
    let result = match req.source.as_str() {
        "horizon" => install_from_horizon(game_dir, &req.project_id, &req.world),
        "modrinth" => install_from_modrinth(
            game_dir,
            &req.project_id,
            &req.kind,
            &req.world,
            req.allow_older,
        ),
        other => Err(format!("Unknown source: {other}")),
    };
    match result {
        Ok(rec) => InstallResponse {
            ok: true,
            installed: Some(rec),
            error: String::new(),
        },
        Err(err) => InstallResponse {
            ok: false,
            installed: None,
            error: err,
        },
    }
}

fn install_from_horizon(
    game_dir: &Path,
    project_id: &str,
    world: &str,
) -> Result<InstalledRecord, String> {
    let (idx, _) = load_horizon_index(game_dir, false)?;
    let p = idx
        .project(project_id)
        .ok_or_else(|| format!("{project_id} is not in Horizon Registry"))?;
    if p.kind == index::Kind::NativeMod {
        return Err(format!("{} is desktop-only and cannot be installed on iOS", p.name));
    }
    let kind_str = horizon_kind_str(&p.kind)
        .ok_or_else(|| format!("Unsupported project kind: {}", p.kind.name()))?;
    let v = idx.installable(p, GAME_VERSION).ok_or_else(|| {
        horizon_blocked_reason(&idx, p)
            .unwrap_or_else(|| format!("{} has no compatible version for {GAME_VERSION}", p.name))
    })?;
    if let Some(r) = idx.revoked(&p.id, &v.file.sha256) {
        return Err(format!("{} was taken down: {}", p.name, r.reason));
    }

    let (target_dir, target_filename, rel_path, world_used) = match kind_str {
        "mod" => {
            let fname = format!("{}.hmod", p.id);
            (
                game_dir.join(mod_list::DIR),
                fname.clone(),
                format!("{}/{fname}", mod_list::DIR),
                String::new(),
            )
        }
        "resourcepack" => {
            if !is_safe_filename(&v.file.name) {
                return Err("Unsafe resource pack filename".into());
            }
            (
                game_dir.join("resourcepacks"),
                v.file.name.clone(),
                format!("resourcepacks/{}", v.file.name),
                String::new(),
            )
        }
        "shader" => {
            if !is_safe_filename(&v.file.name) {
                return Err("Unsafe shader pack filename".into());
            }
            (
                game_dir.join("shaderpacks"),
                v.file.name.clone(),
                format!("shaderpacks/{}", v.file.name),
                String::new(),
            )
        }
        "datapack" => {
            if !is_safe_world_folder(world) {
                return Err("Select a local world before installing a data pack".into());
            }
            if !is_safe_filename(&v.file.name) {
                return Err("Unsafe data pack filename".into());
            }
            let world_dir = game_dir.join("saves").join(world);
            if !world_dir.is_dir() {
                return Err(format!("World not found: {world}"));
            }
            (
                world_dir.join("datapacks"),
                v.file.name.clone(),
                format!("saves/{world}/datapacks/{}", v.file.name),
                world.to_owned(),
            )
        }
        _ => return Err("Unsupported kind".into()),
    };

    let mut manifest = BrowserManifest::load(game_dir);
    let existing = manifest.find("horizon", &p.id, &world_used).cloned();
    let dest_path = target_dir.join(&target_filename);
    let owned_by_this = existing
        .as_ref()
        .is_some_and(|e| e.file == rel_path);
    if dest_path.exists() && !owned_by_this {
        return Err(format!(
            "{rel_path} already exists and was not installed by this browser; remove or rename it first"
        ));
    }

    // Download into staging dir, run full Horizon index verification (size, SHA-256, signature, manifest/content).
    let stage = staging_dir(game_dir);
    let staged_file = download_verified_url(
        &v.file.url,
        &stage,
        &v.file.name,
        v.file.size,
        ChecksumAlgo::Sha256,
        &v.file.sha256,
    )?;
    if let Err(why) = index::check_file(&idx, p, v, &staged_file) {
        let _ = fs::remove_file(&staged_file);
        return Err(why);
    }

    // Detect actual WASM status directly from `.hmod` manifest on disk.
    let is_wasm = if kind_str == "mod" {
        Package::read(&staged_file)
            .map(|pkg| pkg.manifest.wasm.is_some())
            .unwrap_or_else(|_| horizon_is_wasm_hint(p))
    } else {
        false
    };

    fs::create_dir_all(&target_dir).map_err(|e| format!("{}: {e}", target_dir.display()))?;
    move_file_replace(&staged_file, &dest_path)?;

    // Remove previous filename if an update changed filenames.
    if let Some(old) = &existing
        && old.file != rel_path
        && is_managed_rel_path(&old.file)
    {
        let _ = fs::remove_file(game_dir.join(&old.file));
    }

    // Wire game config automatically for newly installed mods and datapacks.
    if kind_str == "mod" && existing.is_none() {
        set_mod_enabled(game_dir, &p.id, true)?;
    } else if kind_str == "datapack" {
        let _ = set_world_datapack_enabled(game_dir, &world_used, &target_filename, true);
    }

    let record = InstalledRecord {
        source: "horizon".into(),
        project_id: p.id.clone(),
        slug: p.id.clone(),
        name: p.name.clone(),
        kind: kind_str.to_owned(),
        version_id: v.version.clone(),
        version_number: v.version.clone(),
        file: rel_path,
        checksum: format!("SHA-256:{}", v.file.sha256),
        icon_url: p.icon.clone().unwrap_or_default(),
        world: world_used,
        is_wasm,
        heavy_gpu: horizon_is_heavy_gpu(p),
    };
    manifest.upsert(record.clone());
    manifest.save(game_dir)?;
    Ok(record)
}

fn install_from_modrinth(
    game_dir: &Path,
    project_id: &str,
    kind: &str,
    world: &str,
    allow_older: bool,
) -> Result<InstalledRecord, String> {
    if !matches!(kind, "resourcepack" | "datapack") {
        return Err(
            "Modrinth installs on iOS currently support Resource Packs and Data Packs only".into(),
        );
    }
    let proj_url = format!("{MODRINTH_API_URL}/project/{}", percent_encode(project_id));
    let proj = modrinth_get_json(&proj_url)?;
    let vers_url = format!(
        "{MODRINTH_API_URL}/project/{}/version",
        percent_encode(project_id)
    );
    let vers = modrinth_get_json(&vers_url)?;
    let chosen = pick_modrinth_version_file(&vers, kind, allow_older)
        .ok_or_else(|| "No compatible .zip file with SHA-512 checksum found on Modrinth".to_owned())?;

    if !is_safe_filename(&chosen.filename) {
        return Err(format!("Unsafe filename from Modrinth: {:?}", chosen.filename));
    }

    let id = proj["id"].as_str().unwrap_or(project_id).to_owned();
    let slug = proj["slug"].as_str().unwrap_or(&id).to_owned();
    let name = proj["title"].as_str().unwrap_or(&slug).to_owned();
    let icon_url = proj["icon_url"].as_str().unwrap_or("").to_owned();

    let (target_dir, rel_path, world_used) = if kind == "resourcepack" {
        (
            game_dir.join("resourcepacks"),
            format!("resourcepacks/{}", chosen.filename),
            String::new(),
        )
    } else {
        if !is_safe_world_folder(world) {
            return Err("Select a local world before installing a data pack".into());
        }
        let world_dir = game_dir.join("saves").join(world);
        if !world_dir.is_dir() {
            return Err(format!("World not found: {world}"));
        }
        (
            world_dir.join("datapacks"),
            format!("saves/{world}/datapacks/{}", chosen.filename),
            world.to_owned(),
        )
    };

    let mut manifest = BrowserManifest::load(game_dir);
    let existing = manifest.find("modrinth", &id, &world_used).cloned();
    let dest_path = target_dir.join(&chosen.filename);
    let owned_by_this = existing.as_ref().is_some_and(|e| e.file == rel_path);
    if dest_path.exists() && !owned_by_this {
        return Err(format!(
            "{rel_path} already exists and was not installed by this browser; remove or rename it first"
        ));
    }

    let stage = staging_dir(game_dir);
    let staged_file = download_verified_url(
        &chosen.url,
        &stage,
        &chosen.filename,
        chosen.size,
        ChecksumAlgo::Sha512,
        &chosen.sha512,
    )?;

    let valid = if kind == "resourcepack" {
        validate_resource_pack_zip(&staged_file)
    } else {
        validate_data_pack_zip(&staged_file)
    };
    if let Err(why) = valid {
        let _ = fs::remove_file(&staged_file);
        return Err(why);
    }

    fs::create_dir_all(&target_dir).map_err(|e| format!("{}: {e}", target_dir.display()))?;
    move_file_replace(&staged_file, &dest_path)?;

    if let Some(old) = &existing
        && old.file != rel_path
        && is_managed_rel_path(&old.file)
    {
        let _ = fs::remove_file(game_dir.join(&old.file));
        if kind == "resourcepack" {
            // Preserve enabled slot in options.txt if old file was enabled.
            if let Some(old_name) = Path::new(&old.file).file_name().and_then(|s| s.to_str()) {
                let options_path = game_dir.join(OPTIONS_FILE);
                let mut packs = read_resource_packs_option(&options_path);
                let old_id = format!("file/{old_name}");
                let new_id = format!("file/{}", chosen.filename);
                if let Some(slot) = packs.iter_mut().find(|p| **p == old_id) {
                    *slot = new_id;
                    let _ = write_resource_packs_option(&options_path, &packs);
                }
            }
        }
    }

    if kind == "datapack" {
        let _ = set_world_datapack_enabled(game_dir, &world_used, &chosen.filename, true);
    }

    let record = InstalledRecord {
        source: "modrinth".into(),
        project_id: id,
        slug,
        name,
        kind: kind.to_owned(),
        version_id: chosen.version_id,
        version_number: chosen.version_number,
        file: rel_path,
        checksum: format!("SHA-512:{}", chosen.sha512),
        icon_url,
        world: world_used,
        is_wasm: false,
        heavy_gpu: false,
    };
    manifest.upsert(record.clone());
    manifest.save(game_dir)?;
    Ok(record)
}

fn move_file_replace(from: &Path, to: &Path) -> Result<(), String> {
    if fs::rename(from, to).is_ok() {
        return Ok(());
    }
    // Cross-device fallback: copy to sibling tmp, then rename.
    let name = to.file_name().and_then(|s| s.to_str()).unwrap_or("file");
    let tmp = to.with_file_name(format!(".{name}.tmp.{}", std::process::id()));
    fs::copy(from, &tmp).map_err(|e| format!("Copy failed: {e}"))?;
    fs::rename(&tmp, to).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        format!("Move failed: {e}")
    })?;
    let _ = fs::remove_file(from);
    Ok(())
}

// ============================================================================
// Installed Scanner (merges mod-browser.json + manual disk files)
// ============================================================================

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InstalledItemView {
    /// Identifier passed back to toggle/reorder/select/remove:
    /// - mod: mod ID (manifest id or filename stem)
    /// - resourcepack: filename in `resourcepacks/`
    /// - shader: `horizon:<id>` or classic filename
    /// - datapack: filename in `saves/<world>/datapacks/`
    pub key: String,
    pub file: String,
    pub name: String,
    pub version: String,
    pub description: String,
    pub source: String,
    pub project_id: String,
    pub icon_url: String,
    pub kind: String,
    pub enabled: bool,
    pub managed: bool,
    pub is_wasm: bool,
    pub heavy_gpu: bool,
    pub traces: bool,
    pub size_bytes: u64,
    pub checksum: String,
    pub update_version: String,
    pub has_update: bool,
    pub revoked_reason: String,
    pub capabilities: Vec<String>,
    pub priority_index: i32,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InstalledOverview {
    pub mods: Vec<InstalledItemView>,
    pub resourcepacks: Vec<InstalledItemView>,
    pub shaders: Vec<InstalledItemView>,
    pub picked_shader: String,
    pub datapacks: Vec<InstalledItemView>,
    pub worlds: Vec<LocalWorldInfo>,
    pub selected_world: String,
    pub updates_count: usize,
    pub total_count: usize,
}

fn path_size(path: &Path) -> u64 {
    let Ok(meta) = fs::symlink_metadata(path) else {
        return 0;
    };
    if meta.is_file() {
        return meta.len();
    }
    if !meta.is_dir() {
        return 0;
    }
    let mut total = 0u64;
    if let Ok(entries) = fs::read_dir(path) {
        for entry in entries.flatten() {
            total = total.saturating_add(path_size(&entry.path()));
        }
    }
    total
}

/// Checks cached Horizon Registry index (no network!) for updates / takedowns on a record.
fn horizon_cached_update_and_revocation(
    cached_index: Option<&Index>,
    rec: &InstalledRecord,
) -> (String, String) {
    let Some(idx) = cached_index.filter(|_| rec.source == "horizon") else {
        return (String::new(), String::new());
    };
    let Some(p) = idx.project(&rec.project_id) else {
        return (String::new(), String::new());
    };
    let sha = rec
        .checksum
        .strip_prefix("SHA-256:")
        .unwrap_or(&rec.checksum);
    let revoked = idx
        .revoked(&p.id, sha)
        .map(|r| r.reason.clone())
        .unwrap_or_default();
    let update = idx
        .installable(p, GAME_VERSION)
        .filter(|v| v.version != rec.version_id)
        .map(|v| v.version.clone())
        .unwrap_or_default();
    (update, revoked)
}

fn load_cached_index_offline_only(game_dir: &Path) -> Option<Index> {
    if let Ok(guard) = INDEX_MEM_CACHE.lock()
        && let Some((_, idx)) = guard.get(game_dir)
    {
        return Some(idx.clone());
    }
    let text = fs::read_to_string(index_cache_path(game_dir)).ok()?;
    Index::parse(&text).ok()
}

/// Scans `Documents/` for all installed mods, resource packs, shaders, and world datapacks
/// (both browser-installed and manually imported), returning a complete UI overview.
pub fn list_installed_overview(
    game_dir: &Path,
    selected_world: &str,
    pending_updates: Option<&HashMap<(String, String, String), String>>,
) -> InstalledOverview {
    let manifest = BrowserManifest::load(game_dir);
    let cached_index = load_cached_index_offline_only(game_dir);
    let mod_list = ModList::load(game_dir);

    let lookup_update = |rec: &InstalledRecord| -> (String, String) {
        let (h_upd, revoked) = horizon_cached_update_and_revocation(cached_index.as_ref(), rec);
        let upd = pending_updates
            .and_then(|m| {
                m.get(&(
                    rec.source.clone(),
                    rec.project_id.clone(),
                    rec.world.clone(),
                ))
                .cloned()
            })
            .unwrap_or(h_upd);
        (upd, revoked)
    };

    // 1. Mods (`horizon-mods/`)
    let mut mods: Vec<InstalledItemView> = Vec::new();
    let mods_dir = game_dir.join(mod_list::DIR);
    let mut mod_paths: Vec<PathBuf> = fs::read_dir(&mods_dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
            if name.starts_with('.') {
                return false;
            }
            (p.is_file() && name.to_ascii_lowercase().ends_with(".hmod"))
                || (p.is_dir() && p.join("horizon-mod.toml").is_file())
        })
        .collect();
    mod_paths.sort();

    for path in mod_paths {
        let file = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or_default()
            .to_owned();
        let rel = format!("{}/{file}", mod_list::DIR);
        let rec = manifest.entries.iter().find(|e| e.file == rel);

        let (id, name, version, description, is_wasm, capabilities) = match Package::read(&path) {
            Ok(pkg) => {
                let m = pkg.manifest;
                let caps = m
                    .capabilities
                    .iter()
                    .map(|c| c.describe().to_owned())
                    .collect();
                (
                    m.id,
                    m.name,
                    m.version,
                    m.description,
                    m.wasm.is_some(),
                    caps,
                )
            }
            Err(_) => {
                let stem = path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or(&file)
                    .to_owned();
                let fallback_name = rec.map_or_else(|| stem.clone(), |r| r.name.clone());
                let fallback_ver = rec.map_or_else(String::new, |r| r.version_number.clone());
                (
                    stem,
                    fallback_name,
                    fallback_ver,
                    String::new(),
                    rec.is_some_and(|r| r.is_wasm),
                    Vec::new(),
                )
            }
        };
        let (update_version, revoked_reason) = rec.map_or_else(
            || (String::new(), String::new()),
            lookup_update,
        );
        let enabled = mod_list.enabled.contains(&id);
        mods.push(InstalledItemView {
            key: id,
            file,
            name,
            version,
            description,
            source: rec.map_or_else(|| "manual".into(), |r| r.source.clone()),
            project_id: rec.map_or_else(String::new, |r| r.project_id.clone()),
            icon_url: rec.map_or_else(String::new, |r| r.icon_url.clone()),
            kind: "mod".into(),
            enabled,
            managed: rec.is_some(),
            is_wasm,
            heavy_gpu: false,
            traces: false,
            size_bytes: path_size(&path),
            checksum: rec.map_or_else(String::new, |r| r.checksum.clone()),
            has_update: !update_version.is_empty(),
            update_version,
            revoked_reason,
            capabilities,
            priority_index: -1,
        });
    }
    mods.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));

    // 2. Resource Packs (`resourcepacks/` + `options.txt` priority order!)
    let options_path = game_dir.join(OPTIONS_FILE);
    let enabled_rps = read_resource_packs_option(&options_path);
    // Display priority order: highest priority first (reverse of bottom-first options.txt).
    let priority_order: Vec<String> = enabled_rps
        .iter()
        .rev()
        .filter_map(|id| id.strip_prefix("file/").map(str::to_owned))
        .collect();

    let rp_dir = game_dir.join("resourcepacks");
    let mut rp_paths: Vec<PathBuf> = fs::read_dir(&rp_dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
            if name.starts_with('.') {
                return false;
            }
            (p.is_file() && name.to_ascii_lowercase().ends_with(".zip"))
                || (p.is_dir() && p.join("pack.mcmeta").is_file())
        })
        .collect();
    rp_paths.sort();

    let mut resourcepacks: Vec<InstalledItemView> = Vec::new();
    for path in rp_paths {
        let file = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or_default()
            .to_owned();
        let rel = format!("resourcepacks/{file}");
        let rec = manifest.entries.iter().find(|e| e.file == rel);
        let prio = priority_order.iter().position(|n| n == &file);
        let (update_version, revoked_reason) = rec.map_or_else(
            || (String::new(), String::new()),
            lookup_update,
        );
        let desc = read_pack_mcmeta_description(&path).unwrap_or_default();
        let display_name = rec.map_or_else(
            || file.strip_suffix(".zip").unwrap_or(&file).to_owned(),
            |r| r.name.clone(),
        );
        resourcepacks.push(InstalledItemView {
            key: file.clone(),
            file,
            name: display_name,
            version: rec.map_or_else(String::new, |r| r.version_number.clone()),
            description: desc,
            source: rec.map_or_else(|| "manual".into(), |r| r.source.clone()),
            project_id: rec.map_or_else(String::new, |r| r.project_id.clone()),
            icon_url: rec.map_or_else(String::new, |r| r.icon_url.clone()),
            kind: "resourcepack".into(),
            enabled: prio.is_some(),
            managed: rec.is_some(),
            is_wasm: false,
            heavy_gpu: false,
            traces: false,
            size_bytes: path_size(&path),
            checksum: rec.map_or_else(String::new, |r| r.checksum.clone()),
            has_update: !update_version.is_empty(),
            update_version,
            revoked_reason,
            capabilities: Vec::new(),
            priority_index: prio.map_or(-1, |i| i as i32),
        });
    }
    // Enabled packs sorted by priority (0 = highest), then disabled packs alphabetically.
    resourcepacks.sort_by(|a, b| match (a.enabled, b.enabled) {
        (true, true) => a.priority_index.cmp(&b.priority_index),
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        (false, false) => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
    });

    // 3. Shaders (`shaderpacks/` + `horizon-graphics.txt` `pickedShaderPack`)
    let picked_shader = read_picked_shader_pack(game_dir);
    let sp_dir = game_dir.join("shaderpacks");
    let mut sp_paths: Vec<PathBuf> = fs::read_dir(&sp_dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
            if name.starts_with('.') {
                return false;
            }
            horizon_shader_api::package::is_pack(p)
                || (p.is_file() && name.to_ascii_lowercase().ends_with(".zip"))
                || (p.is_dir() && p.join("shaders").is_dir())
        })
        .collect();
    sp_paths.sort();

    let mut shaders: Vec<InstalledItemView> = Vec::new();
    for path in sp_paths {
        let file = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or_default()
            .to_owned();
        let rel = format!("shaderpacks/{file}");
        let rec = manifest.entries.iter().find(|e| e.file == rel);
        let (key, title, _is_horizon, traces) = shader_key_for_path(&path);
        let (update_version, revoked_reason) = rec.map_or_else(
            || (String::new(), String::new()),
            lookup_update,
        );
        let selected = !picked_shader.is_empty()
            && (picked_shader == key || picked_shader == file);
        let name = rec
            .map(|r| r.name.clone())
            .filter(|n| !n.is_empty())
            .unwrap_or(title);
        let heavy_gpu = traces || rec.is_some_and(|r| r.heavy_gpu);
        shaders.push(InstalledItemView {
            key,
            file,
            name,
            version: rec.map_or_else(String::new, |r| r.version_number.clone()),
            description: String::new(),
            source: rec.map_or_else(|| "manual".into(), |r| r.source.clone()),
            project_id: rec.map_or_else(String::new, |r| r.project_id.clone()),
            icon_url: rec.map_or_else(String::new, |r| r.icon_url.clone()),
            kind: "shader".into(),
            enabled: selected,
            managed: rec.is_some(),
            is_wasm: false,
            heavy_gpu,
            traces,
            size_bytes: path_size(&path),
            checksum: rec.map_or_else(String::new, |r| r.checksum.clone()),
            has_update: !update_version.is_empty(),
            update_version,
            revoked_reason,
            capabilities: Vec::new(),
            priority_index: -1,
        });
    }
    shaders.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));

    // 4. Local worlds + Data Packs (`saves/<world>/datapacks/` + `datapacks.json`)
    let worlds = prelauncher::scan_local_worlds(&game_dir.join("saves"));
    let active_world = if !selected_world.is_empty()
        && worlds.iter().any(|w| w.folder == selected_world)
    {
        selected_world.to_owned()
    } else {
        worlds
            .first()
            .map(|w| w.folder.clone())
            .unwrap_or_default()
    };

    let mut datapacks: Vec<InstalledItemView> = Vec::new();
    if !active_world.is_empty() && is_safe_world_folder(&active_world) {
        let world_dir = game_dir.join("saves").join(&active_world);
        let (_, disabled_dps) = read_datapacks_json(&world_dir);
        let dp_dir = world_dir.join("datapacks");
        let mut dp_paths: Vec<PathBuf> = fs::read_dir(&dp_dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
                if name.starts_with('.') {
                    return false;
                }
                (p.is_file() && name.to_ascii_lowercase().ends_with(".zip"))
                    || (p.is_dir() && p.join("pack.mcmeta").is_file())
            })
            .collect();
        dp_paths.sort();

        for path in dp_paths {
            let file = path
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or_default()
                .to_owned();
            let rel = format!("saves/{active_world}/datapacks/{file}");
            let rec = manifest.entries.iter().find(|e| e.file == rel);
            let (update_version, revoked_reason) = rec.map_or_else(
                || (String::new(), String::new()),
                lookup_update,
            );
            let enabled = !disabled_dps.iter().any(|d| d == &format!("file/{file}"));
            let desc = read_pack_mcmeta_description(&path).unwrap_or_default();
            let display_name = rec.map_or_else(
                || file.strip_suffix(".zip").unwrap_or(&file).to_owned(),
                |r| r.name.clone(),
            );
            datapacks.push(InstalledItemView {
                key: file.clone(),
                file,
                name: display_name,
                version: rec.map_or_else(String::new, |r| r.version_number.clone()),
                description: desc,
                source: rec.map_or_else(|| "manual".into(), |r| r.source.clone()),
                project_id: rec.map_or_else(String::new, |r| r.project_id.clone()),
                icon_url: rec.map_or_else(String::new, |r| r.icon_url.clone()),
                kind: "datapack".into(),
                enabled,
                managed: rec.is_some(),
                is_wasm: false,
                heavy_gpu: false,
                traces: false,
                size_bytes: path_size(&path),
                checksum: rec.map_or_else(String::new, |r| r.checksum.clone()),
                has_update: !update_version.is_empty(),
                update_version,
                revoked_reason,
                capabilities: Vec::new(),
                priority_index: -1,
            });
        }
        datapacks.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    }

    let updates_count = mods.iter().filter(|i| i.has_update).count()
        + resourcepacks.iter().filter(|i| i.has_update).count()
        + shaders.iter().filter(|i| i.has_update).count()
        + datapacks.iter().filter(|i| i.has_update).count();
    let total_count = mods.len() + resourcepacks.len() + shaders.len() + datapacks.len();

    InstalledOverview {
        mods,
        resourcepacks,
        shaders,
        picked_shader,
        datapacks,
        worlds,
        selected_world: active_world,
        updates_count,
        total_count,
    }
}

// ============================================================================
// Update Checking & Batch Updates
// ============================================================================

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AvailableUpdate {
    pub source: String,
    pub project_id: String,
    pub name: String,
    pub kind: String,
    pub world: String,
    pub current_version: String,
    pub latest_version: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CheckUpdatesResponse {
    pub ok: bool,
    pub updates: Vec<AvailableUpdate>,
    pub count: usize,
    pub error: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct UpdateRequest {
    #[serde(default)]
    pub update_all: bool,
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub project_id: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub world: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UpdateResponse {
    pub ok: bool,
    pub updated: Vec<String>,
    pub failed: Vec<String>,
    pub error: String,
}

/// Pure update detection for Horizon Registry records against a parsed `Index`.
pub fn detect_horizon_updates(index: &Index, manifest: &BrowserManifest) -> Vec<AvailableUpdate> {
    let mut updates = Vec::new();
    for rec in &manifest.entries {
        if rec.source != "horizon" {
            continue;
        }
        let Some(p) = index.project(&rec.project_id) else {
            continue;
        };
        if p.kind == index::Kind::NativeMod {
            continue;
        }
        if let Some(v) = index.installable(p, GAME_VERSION)
            && v.version != rec.version_id
        {
            updates.push(AvailableUpdate {
                source: "horizon".into(),
                project_id: rec.project_id.clone(),
                name: rec.name.clone(),
                kind: rec.kind.clone(),
                world: rec.world.clone(),
                current_version: rec.version_number.clone(),
                latest_version: v.version.clone(),
            });
        }
    }
    updates
}

/// Checks for available updates across all managed entries in `mod-browser.json`.
pub fn check_updates(game_dir: &Path, force_refresh: bool) -> CheckUpdatesResponse {
    let manifest = BrowserManifest::load(game_dir);
    let mut updates = Vec::new();
    let mut errors = Vec::new();

    if manifest.entries.iter().any(|e| e.source == "horizon") {
        match load_horizon_index(game_dir, force_refresh) {
            Ok((idx, _)) => updates.extend(detect_horizon_updates(&idx, &manifest)),
            Err(e) => errors.push(e),
        }
    }

    for rec in manifest.entries.iter().filter(|e| e.source == "modrinth") {
        let vers_url = format!(
            "{MODRINTH_API_URL}/project/{}/version",
            percent_encode(&rec.project_id)
        );
        match modrinth_get_json(&vers_url) {
            Ok(vers) => {
                if let Some(chosen) = pick_modrinth_version_file(&vers, &rec.kind, true)
                    && chosen.version_id != rec.version_id
                {
                    updates.push(AvailableUpdate {
                        source: "modrinth".into(),
                        project_id: rec.project_id.clone(),
                        name: rec.name.clone(),
                        kind: rec.kind.clone(),
                        world: rec.world.clone(),
                        current_version: rec.version_number.clone(),
                        latest_version: chosen.version_number,
                    });
                }
            }
            Err(e) => errors.push(format!("{}: {e}", rec.name)),
        }
    }

    let count = updates.len();
    CheckUpdatesResponse {
        ok: errors.is_empty() || count > 0,
        updates,
        count,
        error: errors.join("; "),
    }
}

/// Updates one item or all updatable items in `mod-browser.json`.
pub fn run_update(game_dir: &Path, req: &UpdateRequest) -> UpdateResponse {
    if !req.update_all {
        let res = install_project(
            game_dir,
            &InstallRequest {
                source: req.source.clone(),
                project_id: req.project_id.clone(),
                kind: req.kind.clone(),
                world: req.world.clone(),
                allow_older: true,
            },
        );
        return if res.ok {
            let label = res
                .installed
                .map_or_else(|| req.project_id.clone(), |r| format!("{} {}", r.name, r.version_number));
            UpdateResponse {
                ok: true,
                updated: vec![label],
                failed: Vec::new(),
                error: String::new(),
            }
        } else {
            UpdateResponse {
                ok: false,
                updated: Vec::new(),
                failed: vec![format!("{}: {}", req.project_id, res.error)],
                error: res.error,
            }
        };
    }

    let check = check_updates(game_dir, true);
    let mut updated = Vec::new();
    let mut failed = Vec::new();
    for item in check.updates {
        let res = install_project(
            game_dir,
            &InstallRequest {
                source: item.source.clone(),
                project_id: item.project_id.clone(),
                kind: item.kind.clone(),
                world: item.world.clone(),
                allow_older: true,
            },
        );
        if res.ok {
            updated.push(format!("{} {}", item.name, item.latest_version));
        } else {
            failed.push(format!("{}: {}", item.name, res.error));
        }
    }
    UpdateResponse {
        ok: failed.is_empty(),
        updated,
        error: failed.join("; "),
        failed,
    }
}

/// Safely removes an installed mod, resource pack, shader pack, or world datapack
/// (works for both browser-installed and manually imported items).
pub fn remove_installed_item(
    game_dir: &Path,
    kind: &str,
    key: &str,
    world: &str,
) -> Result<(), String> {
    let mut manifest = BrowserManifest::load(game_dir);
    let overview = list_installed_overview(game_dir, world, None);

    match kind {
        "mod" => {
            let item = overview
                .mods
                .iter()
                .find(|m| m.key == key || m.file == key)
                .ok_or_else(|| format!("Mod not found: {key}"))?;
            let rel = format!("{}/{}", mod_list::DIR, item.file);
            if !is_managed_rel_path(&rel) {
                return Err("Refusing to remove unsafe path".into());
            }
            remove_path(&game_dir.join(&rel))?;
            let _ = set_mod_enabled(game_dir, &item.key, false);
            manifest.entries.retain(|e| e.file != rel);
            manifest.save(game_dir)?;
            Ok(())
        }
        "resourcepack" => {
            if !is_safe_filename(key) {
                return Err("Invalid resource pack filename".into());
            }
            let rel = format!("resourcepacks/{key}");
            remove_path(&game_dir.join(&rel))?;
            let _ = set_resource_pack_enabled(game_dir, key, false);
            manifest.entries.retain(|e| e.file != rel);
            manifest.save(game_dir)?;
            Ok(())
        }
        "shader" => {
            let item = overview
                .shaders
                .iter()
                .find(|s| s.key == key || s.file == key)
                .ok_or_else(|| format!("Shader pack not found: {key}"))?;
            let rel = format!("shaderpacks/{}", item.file);
            if !is_managed_rel_path(&rel) {
                return Err("Refusing to remove unsafe path".into());
            }
            remove_path(&game_dir.join(&rel))?;
            let picked = read_picked_shader_pack(game_dir);
            if picked == item.key || picked == item.file {
                let _ = set_picked_shader_pack(game_dir, "");
            }
            manifest.entries.retain(|e| e.file != rel);
            manifest.save(game_dir)?;
            Ok(())
        }
        "datapack" => {
            if !is_safe_world_folder(world) || !is_safe_filename(key) {
                return Err("Invalid world or data pack name".into());
            }
            let world_dir = game_dir.join("saves").join(world);
            let rel = format!("saves/{world}/datapacks/{key}");
            if !is_managed_rel_path(&rel) {
                return Err("Refusing to remove unsafe path".into());
            }
            remove_path(&game_dir.join(&rel))?;
            let _ = forget_world_datapack(&world_dir, key);
            manifest.entries.retain(|e| e.file != rel);
            manifest.save(game_dir)?;
            Ok(())
        }
        other => Err(format!("Unknown kind: {other}")),
    }
}

fn remove_path(path: &Path) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.is_dir() => fs::remove_dir_all(path).map_err(|e| e.to_string()),
        Ok(_) => fs::remove_file(path).map_err(|e| e.to_string()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

// ============================================================================
// Bounded Disk Cache for Project Icons (64 MiB cap, oldest-file eviction)
// ============================================================================

/// Fetches (or returns cached) project icon on disk under `Documents/mod-browser/images/`.
pub fn fetch_or_get_icon_path(game_dir: &Path, icon_url: &str) -> Result<PathBuf, String> {
    let url = icon_url.trim();
    if !is_allowed_image_url(url) {
        return Err("Icon host is not allowed".into());
    }
    let dir = game_dir.join(IMAGES_CACHE_REL);
    let hash = hex_lower(&Sha256::digest(url.as_bytes()));
    let target = dir.join(format!("{hash}.img"));
    if target.is_file() {
        return Ok(target);
    }
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let response = http_agent().get(url).call().map_err(|e| e.to_string())?;
    if !is_allowed_image_url(response.get_url()) {
        return Err("Redirected icon host is not allowed".into());
    }
    let mut bytes = Vec::new();
    response
        .into_reader()
        .take(MAX_ICON_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.is_empty() || bytes.len() as u64 > MAX_ICON_BYTES {
        return Err("Icon is empty or exceeds size limit".into());
    }
    let tmp = dir.join(format!(".{hash}.{}.tmp", std::process::id()));
    let write_res = fs::write(&tmp, &bytes).and_then(|()| fs::rename(&tmp, &target));
    if write_res.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    write_res.map_err(|e| e.to_string())?;
    prune_icon_cache(&dir, ICON_CACHE_MAX_BYTES);
    Ok(target)
}

/// Evicts oldest-modified cached icon files until total directory size is `<= max_bytes`.
pub fn prune_icon_cache(dir: &Path, max_bytes: u64) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut total = 0u64;
    let mut files: Vec<(SystemTime, PathBuf, u64)> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = fs::symlink_metadata(&path) else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        let len = meta.len();
        total = total.saturating_add(len);
        let modified = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH);
        files.push((modified, path, len));
    }
    if total <= max_bytes {
        return;
    }
    files.sort_by_key(|(m, _, _)| *m);
    for (_, path, len) in files {
        if total <= max_bytes {
            break;
        }
        if fs::remove_file(&path).is_ok() {
            total = total.saturating_sub(len);
        }
    }
}

/// Convenience helper returning category labels for UI chips.
pub fn categories_map_for_ui() -> BTreeMap<&'static str, Vec<&'static str>> {
    let mut map = BTreeMap::new();
    map.insert("horizon_mod", index::page::categories(&index::Kind::Mod).to_vec());
    map.insert(
        "horizon_resourcepack",
        index::page::categories(&index::Kind::ResourcePack).to_vec(),
    );
    map.insert(
        "horizon_shader",
        index::page::categories(&index::Kind::Shader).to_vec(),
    );
    map.insert(
        "horizon_datapack",
        index::page::categories(&index::Kind::DataPack).to_vec(),
    );
    map.insert("modrinth_resourcepack", MODRINTH_RP_CATEGORIES.to_vec());
    map.insert("modrinth_datapack", MODRINTH_DP_CATEGORIES.to_vec());
    map
}

// ============================================================================
// Unit Tests (runnable on Linux host via `cargo test -p horizon-ios --lib`)
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn temp_dir(tag: &str) -> PathBuf {
        static SEQ: AtomicU64 = AtomicU64::new(1);
        let id = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "horizon-ios-modmgr-{tag}-{}-{id}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_zip(path: &Path, entries: &[(&str, &[u8])]) {
        if let Some(p) = path.parent() {
            fs::create_dir_all(p).unwrap();
        }
        let file = fs::File::create(path).unwrap();
        let mut zw = zip::ZipWriter::new(file);
        let opts = zip::write::SimpleFileOptions::default();
        for (name, data) in entries {
            zw.start_file(*name, opts).unwrap();
            zw.write_all(data).unwrap();
        }
        zw.finish().unwrap();
    }

    #[test]
    fn host_allowlist_and_filename_sanitization() {
        assert!(is_allowed_download_url(
            "https://cdn.modrinth.com/data/abc/versions/1/pack.zip"
        ));
        assert!(is_allowed_download_url(
            "https://horizon-rust.github.io/horizon-mods/index.json"
        ));
        assert!(is_allowed_download_url(
            "https://github.com/horizon-rust/horizon-mods/releases/download/zoom-3.0.3/zoom-3.0.3.hmod"
        ));
        assert!(is_allowed_download_url(
            "https://objects.githubusercontent.com/github-production-release-asset/123"
        ));
        assert!(is_allowed_download_url(
            "https://release-assets.githubusercontent.com/github-production-release-asset/456"
        ));

        // Disallowed schemes, hosts, userinfo, non-release GitHub URLs
        assert!(!is_allowed_download_url("http://cdn.modrinth.com/a.zip"));
        assert!(!is_allowed_download_url("https://evil.example.com/a.zip"));
        assert!(!is_allowed_download_url(
            "https://cdn.modrinth.com@evil.example.com/a.zip"
        ));
        assert!(!is_allowed_download_url("https://github.com/user/repo/archive/main.zip"));
        assert!(!is_allowed_download_url(
            "https://github.com/user/repo/releases/download/../evil/a.zip"
        ));

        // Safe vs unsafe filenames
        assert!(is_safe_filename("zoom-3.0.3.hmod"));
        assert!(is_safe_filename("Faithful 32x.zip"));
        assert!(!is_safe_filename(""));
        assert!(!is_safe_filename(".hidden.zip"));
        assert!(!is_safe_filename("../escape.zip"));
        assert!(!is_safe_filename("sub/file.zip"));
        assert!(!is_safe_filename(r"sub\file.zip"));
        assert!(!is_safe_filename("bad:name.zip"));
    }

    #[test]
    fn verified_download_checks_sha256_sha512_and_cleans_part_on_mismatch() {
        let dir = temp_dir("dl");
        let payload = b"horizon ios verified pack payload";
        let sha256_ok = hex_lower(&Sha256::digest(payload));
        let sha512_ok = hex_lower(&Sha512::digest(payload));

        // SHA-256 success
        let out256 = download_verified_from_reader(
            &payload[..],
            &dir,
            "ok256.hmod",
            payload.len() as u64,
            ChecksumAlgo::Sha256,
            &sha256_ok,
        )
        .unwrap();
        assert_eq!(fs::read(&out256).unwrap(), payload);
        assert!(!dir.join(".ok256.hmod.part").exists());

        // SHA-512 success
        let out512 = download_verified_from_reader(
            &payload[..],
            &dir,
            "ok512.zip",
            payload.len() as u64,
            ChecksumAlgo::Sha512,
            &sha512_ok,
        )
        .unwrap();
        assert_eq!(fs::read(&out512).unwrap(), payload);

        // SHA-256 mismatch rejected and `.part` deleted
        let bad_sha256 = "0".repeat(64);
        let err = download_verified_from_reader(
            &payload[..],
            &dir,
            "bad.hmod",
            payload.len() as u64,
            ChecksumAlgo::Sha256,
            &bad_sha256,
        )
        .unwrap_err();
        assert!(err.contains("checksum mismatch"), "{err}");
        assert!(!dir.join("bad.hmod").exists());
        assert!(!dir.join(".bad.hmod.part").exists());

        // Missing / malformed checksum refused
        let err_missing = download_verified_from_reader(
            &payload[..],
            &dir,
            "nocheck.zip",
            payload.len() as u64,
            ChecksumAlgo::Sha512,
            "",
        )
        .unwrap_err();
        assert!(err_missing.contains("checksum"), "{err_missing}");

        // Size mismatch refused
        let err_size = download_verified_from_reader(
            &payload[..],
            &dir,
            "wrongsize.zip",
            (payload.len() + 10) as u64,
            ChecksumAlgo::Sha256,
            &sha256_ok,
        )
        .unwrap_err();
        assert!(err_size.contains("Incomplete download"), "{err_size}");
        assert!(!dir.join(".wrongsize.zip.part").exists());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn horizon_registry_parsing_filters_native_mods_flags_wasm_and_heavy_shaders() {
        let sha = "a".repeat(64);
        let sha_rt = "b".repeat(64);
        let sha_rev = "c".repeat(64);
        let index_json = serde_json::json!({
            "schema": 1,
            "generated": "2026-11-22T00:00:00Z",
            "projects": [
                {
                    "id": "zoom",
                    "kind": "mod",
                    "name": "Zoom",
                    "summary": "Hold a key to zoom in.",
                    "description": "Now a WebAssembly mod (3.0.0).",
                    "authors": ["Horizon"],
                    "license": "MIT",
                    "source": "https://github.com/horizon-rust/horizon-mods",
                    "categories": ["utility"],
                    "tags": ["zoom"],
                    "downloads": 5000,
                    "versions": [{
                        "version": "3.0.3",
                        "published": "2026-11-19",
                        "api": "0.2",
                        "capabilities": ["registries"],
                        "game": "26.3",
                        "file": {
                            "name": "zoom-3.0.3.hmod",
                            "url": "https://github.com/horizon-rust/horizon-mods/releases/download/zoom-3.0.3/zoom-3.0.3.hmod",
                            "size": 1024,
                            "sha256": sha
                        }
                    }]
                },
                {
                    "id": "desktop_only_mod",
                    "kind": "native-mod",
                    "name": "Desktop Only Mod",
                    "summary": "Uses native Rust dylib.",
                    "authors": ["Someone"],
                    "license": "MIT",
                    "source": "https://github.com/example/desktop-only",
                    "categories": ["utility"],
                    "downloads": 9000,
                    "versions": [{
                        "version": "1.0.0",
                        "published": "2026-11-10",
                        "api": "0.2",
                        "game": "26.3",
                        "file": {
                            "name": "desktop_only_mod-1.0.0.hmod",
                            "url": "https://github.com/horizon-rust/horizon-mods/releases/download/d-1/desktop_only_mod-1.0.0.hmod",
                            "size": 2048,
                            "sha256": sha
                        }
                    }]
                },
                {
                    "id": "vivid_rt",
                    "kind": "shader",
                    "name": "Vivid Raytracing",
                    "summary": "Ray-traced lighting.",
                    "authors": ["Evan"],
                    "license": "MIT",
                    "source": "https://github.com/example/vivid-rt",
                    "categories": ["path-tracing"],
                    "downloads": 1200,
                    "versions": [{
                        "version": "0.9.1",
                        "published": "2026-11-18",
                        "api": horizon_shader_api::API,
                        "game": "26.3",
                        "file": {
                            "name": "vivid_rt-0.9.1.hshader",
                            "url": "https://github.com/horizon-rust/horizon-mods/releases/download/v-1/vivid_rt-0.9.1.hshader",
                            "size": 4096,
                            "sha256": sha_rt
                        }
                    }]
                },
                {
                    "id": "bad_mod",
                    "kind": "mod",
                    "name": "Revoked Mod",
                    "summary": "Taken down.",
                    "authors": ["Bad"],
                    "license": "MIT",
                    "source": "https://github.com/example/bad",
                    "categories": ["utility"],
                    "downloads": 100,
                    "versions": [{
                        "version": "1.0.0",
                        "published": "2026-11-01",
                        "api": "0.2",
                        "game": "26.3",
                        "file": {
                            "name": "bad_mod-1.0.0.hmod",
                            "url": "https://github.com/horizon-rust/horizon-mods/releases/download/b-1/bad_mod-1.0.0.hmod",
                            "size": 512,
                            "sha256": sha_rev
                        }
                    }]
                }
            ],
            "revoked": [{
                "id": "bad_mod",
                "sha256": sha_rev,
                "reason": "Security issue"
            }]
        });

        let idx = Index::parse(&index_json.to_string()).unwrap();
        let manifest = BrowserManifest::default();

        // Default mods search hides native-mod
        let (mods_default, _) = search_horizon_index(
            &idx,
            &manifest,
            &SearchRequest {
                source: "horizon".into(),
                kind: "mod".into(),
                ..Default::default()
            },
        );
        assert_eq!(mods_default.len(), 2);
        assert_eq!(mods_default[0].id, "zoom");
        assert!(mods_default[0].is_wasm);
        assert!(mods_default[0].official);
        assert!(mods_default[0].installable);
        assert_eq!(mods_default[1].id, "bad_mod");
        assert!(!mods_default[1].installable);
        assert!(mods_default[1].blocked_reason.contains("Taken down"));

        // With show_desktop_only = true, native-mod appears badged and non-installable
        let (mods_all, _) = search_horizon_index(
            &idx,
            &manifest,
            &SearchRequest {
                source: "horizon".into(),
                kind: "mod".into(),
                show_desktop_only: true,
                ..Default::default()
            },
        );
        let native = mods_all.iter().find(|m| m.id == "desktop_only_mod").unwrap();
        assert!(native.desktop_only);
        assert!(!native.installable);

        // Shader search marks ray-tracing shader as heavy_gpu
        let (shaders, _) = search_horizon_index(
            &idx,
            &manifest,
            &SearchRequest {
                source: "horizon".into(),
                kind: "shader".into(),
                ..Default::default()
            },
        );
        assert_eq!(shaders.len(), 1);
        assert!(shaders[0].heavy_gpu);
        assert!(shaders[0].installable);
    }

    #[test]
    fn modrinth_search_and_version_picker_handles_datapack_multi_loader_and_sha512() {
        let search_json = serde_json::json!({
            "total_hits": 1,
            "hits": [{
                "project_id": "abc123",
                "slug": "terralith",
                "title": "Terralith",
                "description": "Overworld biomes",
                "author": "StardustLabs",
                "project_type": "mod",
                "downloads": 999999,
                "icon_url": "https://cdn.modrinth.com/data/abc123/icon.png",
                "license": "ARR",
                "versions": ["1.21.4", "26.3"],
                "categories": ["worldgen", "datapack"]
            }]
        });
        let (items, total) =
            parse_modrinth_search_response(&search_json, "datapack", &BrowserManifest::default(), "");
        assert_eq!(total, 1);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].kind, "datapack");
        assert_eq!(items[0].game_compat, "26.3");

        // Version list contains both a Fabric .jar and a datapack .zip; picker MUST select the .zip!
        let sha512 = "f".repeat(128);
        let versions_json = serde_json::json!([
            {
                "id": "v_fabric",
                "version_number": "2.5.0-fabric",
                "date_published": "2026-11-20T00:00:00Z",
                "game_versions": ["26.3"],
                "loaders": ["fabric"],
                "status": "listed",
                "files": [{
                    "filename": "Terralith.jar",
                    "url": "https://cdn.modrinth.com/data/abc123/versions/v_fabric/Terralith.jar",
                    "size": 1000,
                    "primary": true,
                    "hashes": { "sha512": sha512 }
                }]
            },
            {
                "id": "v_dp",
                "version_number": "2.5.0-dp",
                "date_published": "2026-11-19T00:00:00Z",
                "game_versions": ["26.3"],
                "loaders": ["datapack"],
                "status": "listed",
                "files": [{
                    "filename": "Terralith_dp.zip",
                    "url": "https://cdn.modrinth.com/data/abc123/versions/v_dp/Terralith_dp.zip",
                    "size": 2000,
                    "primary": true,
                    "hashes": { "sha512": sha512 }
                }]
            }
        ]);
        let picked = pick_modrinth_version_file(&versions_json, "datapack", false).unwrap();
        assert_eq!(picked.version_id, "v_dp");
        assert_eq!(picked.filename, "Terralith_dp.zip");
    }

    #[test]
    fn horizon_mods_txt_enable_disable_roundtrip_preserves_keys_and_cap() {
        let dir = temp_dir("mods_txt");
        fs::write(
            dir.join(mod_list::FILE),
            "mod.existing:true\nkey.zoom.in:key.keyboard.z\nwasm.memory_cap_mib:512\n",
        )
        .unwrap();

        set_mod_enabled(&dir, "zoom", true).unwrap();
        let list = ModList::load(&dir);
        assert!(list.enabled.contains("existing"));
        assert!(list.enabled.contains("zoom"));
        assert_eq!(list.wasm_memory_cap_mib, Some(512));
        assert_eq!(list.keys_of("zoom"), [("in", "key.keyboard.z")]);

        set_mod_enabled(&dir, "zoom", false).unwrap();
        let list2 = ModList::load(&dir);
        assert!(!list2.enabled.contains("zoom"));
        assert!(list2.enabled.contains("existing"));
        assert_eq!(list2.wasm_memory_cap_mib, Some(512));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn options_txt_resource_packs_enable_disable_reorder_preserves_unrelated_keys() {
        let dir = temp_dir("rp_opts");
        let opts = dir.join(OPTIONS_FILE);
        fs::write(
            &opts,
            "version:4556\nrenderDistance:12\nkey_key.jump:key.keyboard.space\nresourcePacks:[\"vanilla\"]\nlang:ru_ru\n",
        )
        .unwrap();

        set_resource_pack_enabled(&dir, "Alpha.zip", true).unwrap();
        set_resource_pack_enabled(&dir, "Beta.zip", true).unwrap();
        // Bottom-first: ["vanilla", "file/Alpha.zip", "file/Beta.zip"] (Beta has highest priority!)
        assert_eq!(
            read_resource_packs_option(&opts),
            vec!["vanilla", "file/Alpha.zip", "file/Beta.zip"]
        );

        // Move Alpha UP (higher priority -> swaps above Beta!)
        reorder_resource_pack(&dir, "Alpha.zip", true).unwrap();
        assert_eq!(
            read_resource_packs_option(&opts),
            vec!["vanilla", "file/Beta.zip", "file/Alpha.zip"]
        );

        // Move Beta DOWN (cannot move below vanilla!)
        reorder_resource_pack(&dir, "Beta.zip", false).unwrap();
        assert_eq!(
            read_resource_packs_option(&opts),
            vec!["vanilla", "file/Beta.zip", "file/Alpha.zip"]
        );

        // Move Alpha DOWN (swaps below Beta)
        reorder_resource_pack(&dir, "Alpha.zip", false).unwrap();
        assert_eq!(
            read_resource_packs_option(&opts),
            vec!["vanilla", "file/Alpha.zip", "file/Beta.zip"]
        );

        // Disable Beta
        set_resource_pack_enabled(&dir, "Beta.zip", false).unwrap();
        assert_eq!(
            read_resource_packs_option(&opts),
            vec!["vanilla", "file/Alpha.zip"]
        );

        // Unrelated lines preserved verbatim!
        let text = fs::read_to_string(&opts).unwrap();
        assert!(text.contains("renderDistance:12\n"));
        assert!(text.contains("key_key.jump:key.keyboard.space\n"));
        assert!(text.contains("lang:ru_ru\n"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn shader_selection_reads_and_writes_horizon_graphics_txt_preserving_keys() {
        let dir = temp_dir("shaders");
        let gfx = dir.join(GRAPHICS_FILE);
        fs::write(&gfx, "preset:balanced\nfxaa:true\npickedShaderPack:\n").unwrap();

        assert_eq!(read_picked_shader_pack(&dir), "");
        set_picked_shader_pack(&dir, "horizon:vivid_horizon").unwrap();
        assert_eq!(read_picked_shader_pack(&dir), "horizon:vivid_horizon");

        let raw = fs::read_to_string(&gfx).unwrap();
        assert!(raw.contains("preset:balanced\n"));
        assert!(raw.contains("fxaa:true\n"));
        assert!(raw.contains("pickedShaderPack:horizon:vivid_horizon\n"));

        // Disable shaders
        set_picked_shader_pack(&dir, "").unwrap();
        assert_eq!(read_picked_shader_pack(&dir), "");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn world_datapacks_install_toggle_and_remove() {
        let dir = temp_dir("datapacks");
        let world_dir = dir.join("saves/MyWorld");
        fs::create_dir_all(&world_dir).unwrap();
        fs::write(world_dir.join("level.dat"), b"stub").unwrap();

        let dp_path = world_dir.join("datapacks/cool_dp.zip");
        write_zip(
            &dp_path,
            &[
                (
                    "pack.mcmeta",
                    br#"{"pack":{"pack_format":61,"description":"Cool Data Pack"}}"#,
                ),
                ("data/cool/function/tick.mcfunction", b"say hi\n"),
            ],
        );
        assert_eq!(
            validate_data_pack_zip(&dp_path).unwrap(),
            "Cool Data Pack"
        );

        // New datapack is enabled by default (not in disabled list)
        let ov1 = list_installed_overview(&dir, "MyWorld", None);
        assert_eq!(ov1.datapacks.len(), 1);
        assert!(ov1.datapacks[0].enabled);

        // Disable -> recorded in datapacks.json `disabled`
        set_world_datapack_enabled(&dir, "MyWorld", "cool_dp.zip", false).unwrap();
        let ov2 = list_installed_overview(&dir, "MyWorld", None);
        assert!(!ov2.datapacks[0].enabled);

        // Re-enable -> removed from `disabled`, added to `enabled`
        set_world_datapack_enabled(&dir, "MyWorld", "cool_dp.zip", true).unwrap();
        let ov3 = list_installed_overview(&dir, "MyWorld", None);
        assert!(ov3.datapacks[0].enabled);

        // Remove -> deletes file and cleans datapacks.json
        remove_installed_item(&dir, "datapack", "cool_dp.zip", "MyWorld").unwrap();
        assert!(!dp_path.exists());
        let ov4 = list_installed_overview(&dir, "MyWorld", None);
        assert!(ov4.datapacks.is_empty());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn mod_browser_manifest_update_detection_and_removal() {
        let dir = temp_dir("manifest_upd");
        let mod_file = dir.join("horizon-mods/zoom.hmod");
        fs::create_dir_all(mod_file.parent().unwrap()).unwrap();
        fs::write(&mod_file, b"stub").unwrap();
        set_mod_enabled(&dir, "zoom", true).unwrap();

        let mut manifest = BrowserManifest::default();
        manifest.upsert(InstalledRecord {
            source: "horizon".into(),
            project_id: "zoom".into(),
            slug: "zoom".into(),
            name: "Zoom".into(),
            kind: "mod".into(),
            version_id: "3.0.2".into(),
            version_number: "3.0.2".into(),
            file: "horizon-mods/zoom.hmod".into(),
            checksum: format!("SHA-256:{}", "a".repeat(64)),
            icon_url: String::new(),
            world: String::new(),
            is_wasm: true,
            heavy_gpu: false,
        });
        manifest.save(&dir).unwrap();

        let idx_json = serde_json::json!({
            "schema": 1,
            "projects": [{
                "id": "zoom",
                "kind": "mod",
                "name": "Zoom",
                "summary": "Zoom mod",
                "authors": ["Horizon"],
                "license": "MIT",
                "source": "https://github.com/horizon-rust/horizon-mods",
                "versions": [{
                    "version": "3.0.3",
                    "published": "2026-11-19",
                    "api": "0.2",
                    "game": "26.3",
                    "file": {
                        "name": "zoom-3.0.3.hmod",
                        "url": "https://github.com/horizon-rust/horizon-mods/releases/download/zoom-3.0.3/zoom-3.0.3.hmod",
                        "size": 123,
                        "sha256": "b".repeat(64)
                    }
                }]
            }]
        });
        let idx = Index::parse(&idx_json.to_string()).unwrap();
        let updates = detect_horizon_updates(&idx, &BrowserManifest::load(&dir));
        assert_eq!(updates.len(), 1);
        assert_eq!(updates[0].current_version, "3.0.2");
        assert_eq!(updates[0].latest_version, "3.0.3");

        // Remove cleans up file, horizon-mods.txt, and mod-browser.json
        remove_installed_item(&dir, "mod", "zoom", "").unwrap();
        assert!(!mod_file.exists());
        assert!(!ModList::load(&dir).enabled.contains("zoom"));
        assert!(BrowserManifest::load(&dir).entries.is_empty());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn icon_cache_prunes_oldest_files_over_budget() {
        let dir = temp_dir("icons");
        let a = dir.join("a.img");
        let b = dir.join("b.img");
        let c = dir.join("c.img");
        for (p, secs) in [(&a, 100u64), (&b, 200), (&c, 300)] {
            fs::write(p, [1u8; 10]).unwrap();
            let f = fs::File::options().write(true).open(p).unwrap();
            f.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(secs))
                .unwrap();
        }
        prune_icon_cache(&dir, 20);
        assert!(!a.exists());
        assert!(b.exists());
        assert!(c.exists());
        let _ = fs::remove_dir_all(&dir);
    }
}
