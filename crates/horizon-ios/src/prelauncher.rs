//! Pure-Rust pre-launcher storage, SLP status pinging, world scanning, and resource extraction
//! for `horizon-ios`.
//!
//! Keeps NBT (`servers.dat`), `options.txt`, `horizon-player.txt`, Minecraft SLP ping, and zip
//! extraction in Rust using Horizon's own crates so the Objective-C UIKit pre-launcher stays
//! lightweight and 100% format-compatible with Horizon's in-game screens.

use flate2::read::GzDecoder;
use horizon_client_input::touch_bridge;
use horizon_core::nbt::{self, Tag};
use horizon_protocol::connection::Connection;
use horizon_protocol::packets::{Empty, handshake, status};
use horizon_protocol::servers::{self, ServerEntry};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const PLAYER_FILE: &str = "horizon-player.txt";
const PLAYER_KEY: &str = "name:";

/// Matches `horizon_client::lan::conn::valid_name` (`StringUtil.isValidPlayerName`, 1..=16 ASCII).
pub fn is_valid_player_name(name: &str) -> bool {
    (1..=16).contains(&name.len()) && name.chars().all(|c| (c as u32) > 32 && (c as u32) < 127)
}

fn generate_player_name() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos() as u64);
    let mut x = nanos ^ u64::from(std::process::id()).rotate_left(32);
    x ^= x >> 33;
    x = x.wrapping_mul(0xff51_afd7_ed55_8ccd);
    x ^= x >> 33;
    format!("Player{:05}", x % 100_000)
}

/// Reads `horizon-player.txt` (`name:<nick>`), creating a valid generated name if absent/invalid.
pub fn load_or_create_player_name(dir: &Path) -> String {
    let path = dir.join(PLAYER_FILE);
    if let Ok(text) = fs::read_to_string(&path)
        && let Some(name) = text
            .lines()
            .find_map(|line| line.trim_end_matches('\r').strip_prefix(PLAYER_KEY))
            .filter(|n| is_valid_player_name(n))
    {
        return name.to_owned();
    }
    let generated = generate_player_name();
    let _ = fs::write(&path, format!("{PLAYER_KEY}{generated}\n"));
    generated
}

/// Validates and writes `horizon-player.txt` in Horizon's exact `name:<nick>\n` format.
pub fn save_player_name(dir: &Path, name: &str) -> Result<String, String> {
    let trimmed = name.trim();
    if !is_valid_player_name(trimmed) {
        return Err("Username must be 1–16 ASCII characters with no spaces".into());
    }
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let path = dir.join(PLAYER_FILE);
    let tmp = dir.join(format!("{PLAYER_FILE}.tmp.{}", std::process::id()));
    fs::write(&tmp, format!("{PLAYER_KEY}{trimmed}\n")).map_err(|e| e.to_string())?;
    fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
    Ok(trimmed.to_owned())
}

/// JSON-serializable server row returned to Objective-C.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServerRow {
    pub name: String,
    pub ip: String,
    pub normalized: String,
}

/// Reads the shown servers from `servers.dat` using `horizon_protocol::servers::load`.
pub fn load_servers(path: &Path) -> Vec<ServerRow> {
    let _guard = servers::lock();
    servers::load(path)
        .into_iter()
        .map(|entry| {
            let normalized =
                touch_bridge::normalize_server_address(&entry.ip).unwrap_or_default();
            ServerRow {
                name: entry.name,
                ip: entry.ip,
                normalized,
            }
        })
        .collect()
}

/// Adds (`index == None`) or edits (`index == Some(i)`) a server in `servers.dat`,
/// preserving existing entry metadata (`icon`, `accept_textures`, `accepted_code_of_conduct`)
/// and all hidden entries.
pub fn upsert_server(
    path: &Path,
    index: Option<usize>,
    name: &str,
    ip: &str,
) -> Result<Vec<ServerRow>, String> {
    let ip_trimmed = ip.trim();
    if touch_bridge::normalize_server_address(ip_trimmed).is_none() {
        return Err("Invalid server address".into());
    }
    let name_trimmed = name.trim();
    let final_name = if name_trimmed.is_empty() {
        ip_trimmed
    } else {
        name_trimmed
    };
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let _guard = servers::lock();
    let (mut shown, hidden) = servers::load_all(path);
    match index {
        Some(i) if i < shown.len() => {
            shown[i].name = final_name.to_owned();
            shown[i].ip = ip_trimmed.to_owned();
        }
        _ => {
            shown.push(ServerEntry::new(final_name, ip_trimmed));
        }
    }
    servers::save_all(path, &shown, &hidden).map_err(|e| e.to_string())?;
    Ok(shown
        .into_iter()
        .map(|entry| {
            let normalized =
                touch_bridge::normalize_server_address(&entry.ip).unwrap_or_default();
            ServerRow {
                name: entry.name,
                ip: entry.ip,
                normalized,
            }
        })
        .collect())
}

/// Removes a server at `index` from `servers.dat`, keeping all hidden entries intact.
pub fn delete_server(path: &Path, index: usize) -> Result<Vec<ServerRow>, String> {
    let _guard = servers::lock();
    let (mut shown, hidden) = servers::load_all(path);
    if index >= shown.len() {
        return Err("Server not found".into());
    }
    shown.remove(index);
    servers::save_all(path, &shown, &hidden).map_err(|e| e.to_string())?;
    Ok(shown
        .into_iter()
        .map(|entry| {
            let normalized =
                touch_bridge::normalize_server_address(&entry.ip).unwrap_or_default();
            ServerRow {
                name: entry.name,
                ip: entry.ip,
                normalized,
            }
        })
        .collect())
}

/// Result of a single Minecraft Server List Ping (SLP).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PingResult {
    pub online: bool,
    pub latency_ms: u64,
    pub players_online: i64,
    pub players_max: i64,
    pub version: String,
    pub motd: String,
    pub error: String,
}

fn strip_legacy_codes(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '§' {
            let _ = chars.next();
        } else {
            out.push(c);
        }
    }
    out
}

fn extract_json_text(val: &serde_json::Value, out: &mut String) {
    match val {
        serde_json::Value::String(s) => out.push_str(s),
        serde_json::Value::Array(items) => {
            for item in items {
                extract_json_text(item, out);
            }
        }
        serde_json::Value::Object(map) => {
            if let Some(text) = map.get("text").and_then(|v| v.as_str()) {
                out.push_str(text);
            }
            if let Some(extra) = map.get("extra") {
                extract_json_text(extra, out);
            }
        }
        _ => {}
    }
}

/// Performs a blocking SLP ping using `horizon_protocol` (called on a background queue from iOS).
pub fn ping_server(address: &str, timeout: Duration) -> PingResult {
    let failed = |err: String| PingResult {
        online: false,
        latency_ms: 0,
        players_online: -1,
        players_max: -1,
        version: String::new(),
        motd: String::new(),
        error: err,
    };
    let Some((host, port)) = servers::parse_address(address) else {
        return failed("Invalid address".into());
    };
    let mut conn = match Connection::connect_server(&host, port, timeout) {
        Ok(c) => c,
        Err(e) => return failed(e.to_string()),
    };
    if let Err(e) = conn.reader.set_read_timeout(Some(timeout)) {
        return failed(e.to_string());
    }
    let intention = handshake::Serverbound::Intention(handshake::Intention {
        protocol: horizon_protocol::PROTOCOL_VERSION,
        host,
        port,
        intent: handshake::STATUS,
    })
    .encode();
    if let Err(e) = conn.send(&intention) {
        return failed(e.to_string());
    }
    if let Err(e) = conn.send(&status::Serverbound::StatusRequest(Empty).encode()) {
        return failed(e.to_string());
    }
    let (id, payload) = match conn.recv() {
        Ok(pkt) => pkt,
        Err(e) => return failed(e.to_string()),
    };
    let json: serde_json::Value = match status::Clientbound::decode(id, &payload) {
        Ok(status::Clientbound::StatusResponse(s)) => match serde_json::from_str(&s.json) {
            Ok(v) => v,
            Err(e) => return failed(e.to_string()),
        },
        Ok(_) => return failed("Unexpected status response".into()),
        Err(e) => return failed(e.to_string()),
    };

    let ping_start = Instant::now();
    let latency_ms = if conn
        .send(&status::Serverbound::PingRequest(status::Ping { time: 1 }).encode())
        .is_ok()
        && conn.recv().is_ok()
    {
        ping_start.elapsed().as_millis() as u64
    } else {
        0
    };

    let players_online = json["players"]["online"].as_i64().unwrap_or(-1);
    let players_max = json["players"]["max"].as_i64().unwrap_or(-1);
    let version = json["version"]["name"].as_str().unwrap_or("").to_owned();
    let mut raw_motd = String::new();
    extract_json_text(&json["description"], &mut raw_motd);
    let motd = strip_legacy_codes(&raw_motd)
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join(" ");

    PingResult {
        online: true,
        latency_ms,
        players_online,
        players_max,
        version,
        motd,
        error: String::new(),
    }
}

/// Pre-launcher subset of `Documents/options.txt`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreLauncherOptions {
    pub render_distance: i32,
    pub max_fps: i32,
    pub gui_scale: i32,
    pub fov: i32,
    pub lang: String,
}

impl Default for PreLauncherOptions {
    fn default() -> Self {
        Self {
            render_distance: 12,
            max_fps: 120,
            gui_scale: 0,
            fov: 70,
            lang: "en_us".into(),
        }
    }
}

/// Encodes FOV degrees (`30..=110`) to Minecraft's `options.txt` normalized float string
/// `(deg - 70.0) / 40.0` matching `horizon_client_render::options_file::Spec::Fov`.
pub fn encode_fov_option(deg: i32) -> String {
    let clamped = deg.clamp(30, 110);
    horizon_core::java_number::double_to_string((f64::from(clamped) - 70.0) / 40.0)
}

/// Decodes Minecraft's normalized `options.txt` `fov` float back to degrees (`30..=110`).
pub fn decode_fov_option(raw: &str) -> Option<i32> {
    let v: f64 = raw.trim().parse().ok()?;
    if !v.is_finite() {
        return None;
    }
    let deg = (v * 40.0 + 70.0).round() as i32;
    (30..=110).contains(&deg).then_some(deg)
}

/// Reads the 5 pre-launcher graphics/language keys from `options.txt`, filling defaults if absent.
pub fn load_options(path: &Path) -> PreLauncherOptions {
    let mut opts = PreLauncherOptions::default();
    let Ok(text) = fs::read_to_string(path) else {
        return opts;
    };
    for line in text.lines() {
        let line = line.trim_end_matches('\r');
        let Some((key, val)) = line.split_once(':') else {
            continue;
        };
        match key {
            "renderDistance" => {
                if let Ok(v) = val.trim().parse::<i32>()
                    && (2..=128).contains(&v)
                {
                    opts.render_distance = v;
                }
            }
            "maxFps" => {
                if let Ok(v) = val.trim().parse::<i32>()
                    && (10..=260).contains(&v)
                {
                    opts.max_fps = (v / 10) * 10;
                }
            }
            "guiScale" => {
                if let Ok(v) = val.trim().parse::<i32>()
                    && v >= 0
                {
                    opts.gui_scale = v.min(8);
                }
            }
            "fov" => {
                if let Some(deg) = decode_fov_option(val) {
                    opts.fov = deg;
                }
            }
            "lang" => {
                let s = val.trim();
                if !s.is_empty() {
                    opts.lang = s.to_owned();
                }
            }
            _ => {}
        }
    }
    opts
}

/// Updates the 5 pre-launcher keys in `options.txt` in-place while preserving ALL unrelated
/// lines, comments, custom keys, and original ordering verbatim.
pub fn save_options(path: &Path, opts: &PreLauncherOptions) -> io::Result<()> {
    let rd = opts.render_distance.clamp(2, 128);
    let fps = ((opts.max_fps.clamp(10, 260) + 5) / 10) * 10;
    let fps = fps.clamp(10, 260);
    let gui = opts.gui_scale.clamp(0, 8);
    let fov_encoded = encode_fov_option(opts.fov);
    let lang = if opts.lang.trim().is_empty() {
        "en_us"
    } else {
        opts.lang.trim()
    };

    let updates: [(&str, String); 5] = [
        ("renderDistance", rd.to_string()),
        ("maxFps", fps.to_string()),
        ("guiScale", gui.to_string()),
        ("fov", fov_encoded),
        ("lang", lang.to_owned()),
    ];
    let mut seen = [false; 5];
    let mut lines: Vec<String> = Vec::new();

    if let Ok(existing) = fs::read_to_string(path) {
        for raw_line in existing.lines() {
            let line = raw_line.trim_end_matches('\r');
            if let Some((key, _)) = line.split_once(':')
                && let Some(idx) = updates.iter().position(|(k, _)| *k == key)
            {
                if !seen[idx] {
                    lines.push(format!("{}:{}", updates[idx].0, updates[idx].1));
                    seen[idx] = true;
                }
                continue;
            }
            lines.push(line.to_owned());
        }
    } else {
        // Brand-new file: emit current DATA_VERSION so OptionsFile::parse doesn't treat it as legacy.
        lines.push(format!("version:{}", horizon_core::version::DATA_VERSION));
    }

    for (idx, (k, v)) in updates.iter().enumerate() {
        if !seen[idx] {
            lines.push(format!("{k}:{v}"));
        }
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut body = lines.join("\n");
    body.push('\n');
    let tmp = path.with_extension(format!("txt.tmp.{}", std::process::id()));
    fs::write(&tmp, body)?;
    fs::rename(&tmp, path)
}

/// Metadata for a local singleplayer world in `Documents/saves/<folder>/level.dat`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalWorldInfo {
    pub folder: String,
    pub name: String,
    pub game_type: i32,
    pub size_bytes: u64,
    pub last_played_ms: i64,
}

fn dir_size_bytes(path: &Path) -> u64 {
    let mut total = 0u64;
    let Ok(entries) = fs::read_dir(path) else {
        return 0;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if let Ok(meta) = fs::symlink_metadata(&p) {
            if meta.is_dir() {
                total = total.saturating_add(dir_size_bytes(&p));
            } else {
                total = total.saturating_add(meta.len());
            }
        }
    }
    total
}

fn read_level_dat_summary(level_dat: &Path) -> Option<(String, i32, i64)> {
    let raw = fs::read(level_dat).ok()?;
    let mut decoded = Vec::new();
    let bytes: &[u8] = if raw.starts_with(&[0x1F, 0x8B]) {
        let mut gz = GzDecoder::new(&raw[..]);
        gz.read_to_end(&mut decoded).ok()?;
        &decoded
    } else {
        &raw
    };
    let (root, _) = nbt::read_named(bytes, nbt::Limits::default()).ok()?;
    let data = root.tag.get("Data")?;
    let name = match data.get("LevelName") {
        Some(Tag::String(s)) => s.to_string_lossy(),
        _ => String::new(),
    };
    let game_type = match data.get("GameType") {
        Some(Tag::Int(v)) => *v,
        Some(Tag::Byte(v)) => i32::from(*v),
        _ => 0,
    };
    let last_played = match data.get("LastPlayed") {
        Some(Tag::Long(v)) => *v,
        _ => 0,
    };
    Some((name, game_type, last_played))
}

/// Scans `saves_dir` for valid world folders containing `level.dat`, newest-played first.
pub fn scan_local_worlds(saves_dir: &Path) -> Vec<LocalWorldInfo> {
    let Ok(entries) = fs::read_dir(saves_dir) else {
        return Vec::new();
    };
    let mut worlds = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let level_dat = path.join("level.dat");
        if !level_dat.is_file() {
            continue;
        }
        let Some(folder) = path.file_name().and_then(|s| s.to_str()).map(str::to_owned) else {
            continue;
        };
        let fallback_mtime = fs::metadata(&level_dat)
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map_or(0, |d| d.as_millis() as i64);
        let (parsed_name, game_type, last_played) =
            read_level_dat_summary(&level_dat).unwrap_or_else(|| (String::new(), 0, 0));
        let name = if parsed_name.trim().is_empty() {
            folder.clone()
        } else {
            parsed_name
        };
        let last_played_ms = if last_played > 0 {
            last_played
        } else {
            fallback_mtime
        };
        let size_bytes = dir_size_bytes(&path);
        worlds.push(LocalWorldInfo {
            folder,
            name,
            game_type,
            size_bytes,
            last_played_ms,
        });
    }
    worlds.sort_by(|a, b| {
        b.last_played_ms
            .cmp(&a.last_played_ms)
            .then_with(|| a.name.cmp(&b.name))
    });
    worlds
}

/// Extracts a Horizon resources `.zip` archive into `dest_resources_dir`, automatically stripping
/// nested wrapper folders (e.g. `resources/horizon-resources-26.3/horizon-resources.json`).
pub fn extract_resources_zip(zip_path: &Path, dest_resources_dir: &Path) -> Result<usize, String> {
    let file = fs::File::open(zip_path).map_err(|e| format!("Failed to open archive: {e}"))?;
    let mut archive =
        zip::ZipArchive::new(file).map_err(|e| format!("Invalid or corrupted ZIP archive: {e}"))?;

    // Locate `horizon-resources.json` (preferring shallowest path, ignoring `__MACOSX`).
    let mut manifest_prefix: Option<PathBuf> = None;
    let mut best_depth = usize::MAX;
    for i in 0..archive.len() {
        let entry = archive
            .by_index(i)
            .map_err(|e| format!("Failed to read archive: {e}"))?;
        let Some(rel) = entry.enclosed_name() else {
            continue;
        };
        if rel
            .components()
            .any(|c| matches!(c, Component::Normal(s) if s == "__MACOSX"))
        {
            continue;
        }
        if rel.file_name().is_some_and(|n| n == "horizon-resources.json") {
            let parent = rel.parent().map_or_else(PathBuf::new, Path::to_path_buf);
            let depth = parent.components().count();
            if depth < best_depth {
                best_depth = depth;
                manifest_prefix = Some(parent);
            }
        }
    }

    let Some(prefix) = manifest_prefix else {
        return Err("horizon-resources.json not found in archive".into());
    };

    fs::create_dir_all(dest_resources_dir)
        .map_err(|e| format!("Failed to create resources folder: {e}"))?;

    let mut extracted = 0usize;
    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| format!("Failed to read archive: {e}"))?;
        let Some(rel) = entry.enclosed_name() else {
            continue;
        };
        if rel
            .components()
            .any(|c| matches!(c, Component::Normal(s) if s == "__MACOSX"))
        {
            continue;
        }
        let Ok(stripped) = rel.strip_prefix(&prefix) else {
            continue;
        };
        if stripped.as_os_str().is_empty() {
            continue;
        }
        let target = dest_resources_dir.join(stripped);
        if entry.is_dir() {
            fs::create_dir_all(&target).map_err(|e| e.to_string())?;
        } else {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            let mut out = fs::File::create(&target).map_err(|e| e.to_string())?;
            io::copy(&mut entry, &mut out).map_err(|e| e.to_string())?;
            extracted += 1;
        }
    }

    if !dest_resources_dir.join("horizon-resources.json").is_file() {
        return Err("Failed to extract horizon-resources.json".into());
    }
    Ok(extracted)
}

// ============================================================================
// OTA Update version comparison and deep-link URL builders
// ============================================================================

/// Default AltStore / SideStore / Feather Source v2 manifest URL on GitHub Releases.
pub const DEFAULT_OTA_SOURCE_URL: &str =
    "https://github.com/nggurbanov/horizon-ios/releases/download/ios-latest/source.json";

/// Target sideloading installer preference (mirrors `HorizonOTAInstaller` in Obj-C).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum OtaInstaller {
    Auto = 0,
    Feather = 1,
    SideStore = 2,
    AltStore = 3,
    Direct = 4,
}

impl OtaInstaller {
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::Feather,
            2 => Self::SideStore,
            3 => Self::AltStore,
            4 => Self::Direct,
            _ => Self::Auto,
        }
    }
}

fn parse_numeric_version_parts(raw: &str) -> Vec<u64> {
    let trimmed = raw.trim().trim_start_matches(['v', 'V']);
    let core = trimmed.split(['-', '+']).next().unwrap_or(trimmed);
    core.split('.')
        .map(|part| {
            let digits: String = part.chars().take_while(|c| c.is_ascii_digit()).collect();
            digits.parse::<u64>().unwrap_or(0)
        })
        .collect()
}

/// Strict numeric dot-separated version comparison (e.g. `0.20261122.1000 > 0.20261122.900`).
pub fn compare_version_strings(a: &str, b: &str) -> std::cmp::Ordering {
    let pa = parse_numeric_version_parts(a);
    let pb = parse_numeric_version_parts(b);
    let len = pa.len().max(pb.len());
    for i in 0..len {
        let va = pa.get(i).copied().unwrap_or(0);
        let vb = pb.get(i).copied().unwrap_or(0);
        match va.cmp(&vb) {
            std::cmp::Ordering::Equal => continue,
            ord => return ord,
        }
    }
    std::cmp::Ordering::Equal
}

/// Returns `true` when `(remote_version, remote_build)` is strictly newer than
/// `(local_version, local_build)`. Uses `buildVersion` as a tie-breaker when short versions match.
pub fn is_ota_update_newer(
    local_version: &str,
    local_build: &str,
    remote_version: &str,
    remote_build: &str,
) -> bool {
    let rv = remote_version.trim();
    if rv.is_empty() {
        return false;
    }
    match compare_version_strings(rv, local_version) {
        std::cmp::Ordering::Greater => true,
        std::cmp::Ordering::Less => false,
        std::cmp::Ordering::Equal => {
            let rb = remote_build.trim();
            let lb = local_build.trim();
            if rb.is_empty() {
                return false;
            }
            if lb.is_empty() || lb == "BUILD_NUMBER" {
                return true;
            }
            compare_version_strings(rb, lb) == std::cmp::Ordering::Greater
        }
    }
}

/// RFC 3986 percent-encoding for a query parameter value (`?url=...`).
pub fn percent_encode_query_value(input: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(input.len() + 16);
    for &b in input.as_bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push('%');
            out.push(HEX[(b >> 4) as usize] as char);
            out.push(HEX[(b & 0x0F) as usize] as char);
        }
    }
    out
}

/// Builds the verified upstream install deep link for an `.ipa` URL:
/// - Feather: `feather://install/<raw-https-url>` (NO `?url=` query param)
/// - SideStore: `sidestore://install?url=<percent-encoded-https-url>`
/// - AltStore: `altstore://install?url=<percent-encoded-https-url>`
/// - Direct / Auto fallback: `<raw-https-url>`
pub fn build_ota_install_url(installer: OtaInstaller, ipa_url: &str) -> Option<String> {
    let url = ipa_url.trim();
    if !url.starts_with("https://") && !url.starts_with("http://") {
        return None;
    }
    let built = match installer {
        OtaInstaller::Feather => format!("feather://install/{url}"),
        OtaInstaller::SideStore => {
            format!("sidestore://install?url={}", percent_encode_query_value(url))
        }
        OtaInstaller::AltStore => {
            format!("altstore://install?url={}", percent_encode_query_value(url))
        }
        OtaInstaller::Direct | OtaInstaller::Auto => url.to_owned(),
    };
    Some(built)
}

/// Builds the verified upstream repo-source deep link for a `source.json` URL:
/// - Feather: `feather://source/<raw-https-url>` (NO `?url=` query param)
/// - SideStore: `sidestore://source?url=<percent-encoded-https-url>`
/// - AltStore: `altstore://source?url=<percent-encoded-https-url>`
/// - Direct / Auto fallback: `<raw-https-url>`
pub fn build_ota_source_url(installer: OtaInstaller, source_url: &str) -> Option<String> {
    let url = source_url.trim();
    if !url.starts_with("https://") && !url.starts_with("http://") {
        return None;
    }
    let built = match installer {
        OtaInstaller::Feather => format!("feather://source/{url}"),
        OtaInstaller::SideStore => {
            format!("sidestore://source?url={}", percent_encode_query_value(url))
        }
        OtaInstaller::AltStore => {
            format!("altstore://source?url={}", percent_encode_query_value(url))
        }
        OtaInstaller::Direct | OtaInstaller::Auto => url.to_owned(),
    };
    Some(built)
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::Compression;
    use flate2::write::GzEncoder;
    use horizon_core::nbt::{JavaString, NamedTag};
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn temp_dir(tag: &str) -> PathBuf {
        static SEQ: AtomicU64 = AtomicU64::new(1);
        let id = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "horizon-ios-prelauncher-{tag}-{}-{id}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn options_txt_roundtrip_preserves_unrelated_keys_and_fov_encoding() {
        let dir = temp_dir("options");
        let path = dir.join("options.txt");

        let original = concat!(
            "version:5023\n",
            "ao:true\n",
            "fov:0.5\n",
            "maxFps:60\n",
            "renderDistance:8\n",
            "guiScale:2\n",
            "lang:ru_ru\n",
            "key_key.forward:key.keyboard.w\n",
            "customModFlag:enabled\n",
            "fullscreenResolution:2532x1170@120:24\n",
        );
        fs::write(&path, original).unwrap();

        let loaded = load_options(&path);
        assert_eq!(loaded.render_distance, 8);
        assert_eq!(loaded.max_fps, 60);
        assert_eq!(loaded.gui_scale, 2);
        assert_eq!(loaded.fov, 90);
        assert_eq!(loaded.lang, "ru_ru");

        let updated = PreLauncherOptions {
            render_distance: 12,
            max_fps: 260,
            gui_scale: 0,
            fov: 60,
            lang: "en_us".into(),
        };
        save_options(&path, &updated).unwrap();

        let text = fs::read_to_string(&path).unwrap();
        assert!(text.contains("version:5023\n"));
        assert!(text.contains("ao:true\n"));
        assert!(text.contains("key_key.forward:key.keyboard.w\n"));
        assert!(text.contains("customModFlag:enabled\n"));
        assert!(text.contains("fullscreenResolution:2532x1170@120:24\n"));
        assert!(text.contains("renderDistance:12\n"));
        assert!(text.contains("maxFps:260\n"));
        assert!(text.contains("guiScale:0\n"));
        assert!(text.contains("fov:-0.25\n"));
        assert!(text.contains("lang:en_us\n"));

        let reloaded = load_options(&path);
        assert_eq!(reloaded, updated);

        // Verify exact FOV encoding/decoding across the full slider range 60..=110.
        for deg in 60..=110 {
            let encoded = encode_fov_option(deg);
            assert_eq!(decode_fov_option(&encoded), Some(deg), "fov {deg} -> {encoded}");
        }

        // Fresh options.txt starts with current DATA_VERSION.
        let fresh = dir.join("fresh_options.txt");
        save_options(&fresh, &updated).unwrap();
        let fresh_text = fs::read_to_string(&fresh).unwrap();
        assert!(fresh_text.starts_with(&format!("version:{}\n", horizon_core::version::DATA_VERSION)));
        assert_eq!(load_options(&fresh), updated);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn servers_dat_crud_preserves_metadata_and_hidden_entries() {
        let dir = temp_dir("servers");
        let path = dir.join("servers.dat");

        // Seed servers.dat with one shown entry carrying icon/textures/CoC metadata + one hidden entry.
        let shown_seed = vec![ServerEntry {
            name: "Survival".into(),
            ip: "play.example.com".into(),
            icon: Some("AAAA".into()),
            accept_textures: Some(true),
            accepted_code_of_conduct: 42,
        }];
        let hidden_seed = vec![ServerEntry::new("DirectHidden", "hidden.example.org:25566")];
        servers::save_all(&path, &shown_seed, &hidden_seed).unwrap();

        let rows = load_servers(&path);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].name, "Survival");
        assert_eq!(rows[0].normalized, "play.example.com:25565");

        // Add a second server.
        let rows = upsert_server(&path, None, "Survival", "play.example.com:25566").unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[1].normalized, "play.example.com:25566");

        // Edit first server: metadata must survive untouched.
        let rows = upsert_server(&path, Some(0), "Survival Main", "play.example.com:25565").unwrap();
        assert_eq!(rows[0].name, "Survival Main");
        let (raw_shown, raw_hidden) = servers::load_all(&path);
        assert_eq!(raw_shown[0].icon.as_deref(), Some("AAAA"));
        assert_eq!(raw_shown[0].accept_textures, Some(true));
        assert_eq!(raw_shown[0].accepted_code_of_conduct, 42);
        assert_eq!(raw_hidden, hidden_seed);

        // Delete second server: hidden entry still preserved.
        let rows = delete_server(&path, 1).unwrap();
        assert_eq!(rows.len(), 1);
        let (raw_shown, raw_hidden) = servers::load_all(&path);
        assert_eq!(raw_shown.len(), 1);
        assert_eq!(raw_hidden, hidden_seed);

        // Invalid address rejected without modifying file.
        assert!(upsert_server(&path, None, "Bad", "host:notaport").is_err());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn player_name_and_local_worlds_and_resources_zip_work() {
        let dir = temp_dir("misc");

        // Player name roundtrip
        let generated = load_or_create_player_name(&dir);
        assert!(is_valid_player_name(&generated));
        assert_eq!(load_or_create_player_name(&dir), generated);
        assert_eq!(save_player_name(&dir, "  Steve_42 ").unwrap(), "Steve_42");
        assert_eq!(
            fs::read_to_string(dir.join(PLAYER_FILE)).unwrap(),
            "name:Steve_42\n"
        );
        assert!(save_player_name(&dir, "bad space").is_err());

        // Local world scan from gzipped level.dat
        let world_dir = dir.join("saves").join("my_world");
        fs::create_dir_all(&world_dir).unwrap();
        let level_tag = NamedTag {
            name: JavaString::from(""),
            tag: Tag::compound([(
                "Data",
                Tag::compound([
                    ("LevelName", Tag::String(JavaString::from("Мой мир"))),
                    ("GameType", Tag::Int(1)),
                    ("LastPlayed", Tag::Long(1_700_000_000_000)),
                ]),
            )]),
        };
        let nbt_bytes = nbt::write_named(&level_tag, nbt::Limits::default()).unwrap();
        let mut gz = GzEncoder::new(Vec::new(), Compression::default());
        gz.write_all(&nbt_bytes).unwrap();
        fs::write(world_dir.join("level.dat"), gz.finish().unwrap()).unwrap();

        let worlds = scan_local_worlds(&dir.join("saves"));
        assert_eq!(worlds.len(), 1);
        assert_eq!(worlds[0].folder, "my_world");
        assert_eq!(worlds[0].name, "Мой мир");
        assert_eq!(worlds[0].game_type, 1);
        assert_eq!(worlds[0].last_played_ms, 1_700_000_000_000);

        // Resources zip with nested directory prefix
        let zip_path = dir.join("pack.zip");
        {
            let f = fs::File::create(&zip_path).unwrap();
            let mut zw = zip::ZipWriter::new(f);
            let opts = zip::write::SimpleFileOptions::default();
            zw.start_file("resources/horizon-resources-26.3/horizon-resources.json", opts)
                .unwrap();
            zw.write_all(br#"{"version":"26.3"}"#).unwrap();
            zw.start_file("resources/horizon-resources-26.3/assets/test.txt", opts)
                .unwrap();
            zw.write_all(b"ok").unwrap();
            zw.finish().unwrap();
        }
        let dest = dir.join("resources");
        let count = extract_resources_zip(&zip_path, &dest).unwrap();
        assert_eq!(count, 2);
        assert!(dest.join("horizon-resources.json").is_file());
        assert_eq!(fs::read_to_string(dest.join("assets/test.txt")).unwrap(), "ok");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn ota_version_comparison_handles_semver_and_build_tiebreaker() {
        assert!(is_ota_update_newer(
            "0.1.0",
            "1",
            "0.20261122.845",
            "202611220845"
        ));
        assert!(is_ota_update_newer(
            "0.20261122.845",
            "202611220845",
            "0.20261122.900",
            "202611220900"
        ));
        // Numeric comparison must NOT compare lexicographically ("1000" > "900").
        assert!(is_ota_update_newer(
            "0.20261122.900",
            "202611220900",
            "0.20261122.1000",
            "202611221000"
        ));
        assert!(is_ota_update_newer(
            "0.20261122.2359",
            "202611222359",
            "0.20261123.0",
            "202611230000"
        ));
        // Same short version, higher buildVersion counts as newer.
        assert!(is_ota_update_newer(
            "0.20261122.845",
            "202611220845",
            "0.20261122.845",
            "202611220846"
        ));
        // Identical version and build is NOT newer.
        assert!(!is_ota_update_newer(
            "0.20261122.845",
            "202611220845",
            "0.20261122.845",
            "202611220845"
        ));
        // Lower remote version is NEVER newer even if buildVersion is larger.
        assert!(!is_ota_update_newer(
            "0.20261122.1000",
            "202611221000",
            "0.20261122.900",
            "202611229999"
        ));
        // Unstamped placeholder build counts as older when short versions match.
        assert!(is_ota_update_newer(
            "0.1.0",
            "BUILD_NUMBER",
            "0.1.0",
            "202611220845"
        ));
        // Empty remote version is rejected.
        assert!(!is_ota_update_newer("0.1.0", "1", "", "202611220845"));
    }

    #[test]
    fn ota_deep_link_url_formatting_matches_upstream_schemes() {
        let ipa = "https://github.com/nggurbanov/horizon-ios/releases/download/ios-latest/Horizon.ipa";
        let src = DEFAULT_OTA_SOURCE_URL;
        let enc_ipa = "https%3A%2F%2Fgithub.com%2Fnggurbanov%2Fhorizon-ios%2Freleases%2Fdownload%2Fios-latest%2FHorizon.ipa";
        let enc_src = "https%3A%2F%2Fgithub.com%2Fnggurbanov%2Fhorizon-ios%2Freleases%2Fdownload%2Fios-latest%2Fsource.json";

        // Feather: raw HTTPS URL directly after `/install/` and `/source/`, NO `?url=`.
        assert_eq!(
            build_ota_install_url(OtaInstaller::Feather, ipa).as_deref(),
            Some("feather://install/https://github.com/nggurbanov/horizon-ios/releases/download/ios-latest/Horizon.ipa")
        );
        assert_eq!(
            build_ota_source_url(OtaInstaller::Feather, src).as_deref(),
            Some("feather://source/https://github.com/nggurbanov/horizon-ios/releases/download/ios-latest/source.json")
        );

        // SideStore: `?url=` with RFC 3986 percent-encoding.
        assert_eq!(
            build_ota_install_url(OtaInstaller::SideStore, ipa).as_deref(),
            Some(format!("sidestore://install?url={enc_ipa}").as_str())
        );
        assert_eq!(
            build_ota_source_url(OtaInstaller::SideStore, src).as_deref(),
            Some(format!("sidestore://source?url={enc_src}").as_str())
        );

        // AltStore: `?url=` with RFC 3986 percent-encoding.
        assert_eq!(
            build_ota_install_url(OtaInstaller::AltStore, ipa).as_deref(),
            Some(format!("altstore://install?url={enc_ipa}").as_str())
        );
        assert_eq!(
            build_ota_source_url(OtaInstaller::AltStore, src).as_deref(),
            Some(format!("altstore://source?url={enc_src}").as_str())
        );

        // Direct Safari fallback keeps raw HTTPS URL.
        assert_eq!(
            build_ota_install_url(OtaInstaller::Direct, ipa).as_deref(),
            Some(ipa)
        );

        // Non-HTTP(S) schemes are rejected.
        assert_eq!(build_ota_install_url(OtaInstaller::Feather, "file:///tmp/a.ipa"), None);
        assert_eq!(build_ota_source_url(OtaInstaller::SideStore, ""), None);
    }
}
