#!/usr/bin/env python3
"""Generate an AltStore / SideStore / Feather Source v2 JSON manifest from Horizon.ipa.

Zero external dependencies (Python 3 stdlib only). Reads Payload/*.app/Info.plist
directly from the IPA zip so CFBundleIdentifier, CFBundleShortVersionString,
CFBundleVersion, MinimumOSVersion, privacy descriptions, and byte size are always
exact.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import zipfile

DEFAULT_REPO = "nggurbanov/horizon-ios"
DEFAULT_BUNDLE_ID = "io.github.nggurbanov.horizon-ios"
DEFAULT_TINT_COLOR = "33bd66"
DEFAULT_ENTITLEMENTS = [
    "com.apple.developer.kernel.increased-memory-limit",
]
MAX_VERSION_HISTORY = 5


def short_version_from_build_number(build_number: str) -> str:
    """Derive Apple-valid 3-part SemVer `0.<YYYYMMDD>.<int(HHMM)>` from `YYYYMMDDHHMM`."""
    digits = "".join(ch for ch in build_number.strip() if ch.isdigit())
    if len(digits) >= 12:
        ymd = digits[:8]
        hmm = int(digits[8:12])
        return f"0.{ymd}.{hmm}"
    now = datetime.now(timezone.utc)
    hmm = int(now.strftime("%H%M"))
    return f"0.{now.strftime('%Y%m%d')}.{hmm}"


def extract_ipa_metadata(ipa_path: Path) -> dict:
    """Extract bundle metadata and exact byte size from an .ipa zip archive."""
    if not ipa_path.is_file():
        raise FileNotFoundError(f"IPA file not found: {ipa_path}")

    size = ipa_path.stat().st_size
    with zipfile.ZipFile(ipa_path, "r") as zf:
        plist_member = None
        preferred = "Payload/Horizon.app/Info.plist"
        names = zf.namelist()
        if preferred in names:
            plist_member = preferred
        else:
            for name in sorted(names):
                parts = name.split("/")
                if (
                    len(parts) == 3
                    and parts[0] == "Payload"
                    and parts[1].endswith(".app")
                    and parts[2] == "Info.plist"
                ):
                    plist_member = name
                    break
        if plist_member is None:
            raise ValueError(f"Info.plist not found inside IPA: {ipa_path}")
        raw_plist = zf.read(plist_member)

    info = plistlib.loads(raw_plist)
    bundle_id = str(info.get("CFBundleIdentifier") or DEFAULT_BUNDLE_ID).strip()
    short_version = str(info.get("CFBundleShortVersionString") or "0.1.0").strip()
    build_version = str(info.get("CFBundleVersion") or "1").strip()
    min_os = str(info.get("MinimumOSVersion") or "15.0").strip()
    display_name = str(
        info.get("CFBundleDisplayName") or info.get("CFBundleName") or "Horizon"
    ).strip()

    privacy: dict[str, str] = {}
    for key in sorted(info.keys()):
        if isinstance(key, str) and key.startswith("NS") and key.endswith("UsageDescription"):
            val = info[key]
            if isinstance(val, str) and val.strip():
                privacy[key] = val.strip()

    return {
        "name": display_name,
        "bundleIdentifier": bundle_id,
        "version": short_version,
        "buildVersion": build_version,
        "minOSVersion": min_os,
        "size": size,
        "privacy": privacy,
    }


def _load_previous_versions(prev_source_path: Path | None, bundle_id: str) -> list[dict]:
    if prev_source_path is None or not prev_source_path.is_file():
        return []
    try:
        raw = json.loads(prev_source_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    apps = raw.get("apps")
    if not isinstance(apps, list):
        return []
    for app in apps:
        if not isinstance(app, dict):
            continue
        if app.get("bundleIdentifier") != bundle_id:
            continue
        versions = app.get("versions")
        if isinstance(versions, list):
            return [v for v in versions if isinstance(v, dict)]
    return []


def build_source_manifest(
    ipa_path: Path,
    download_url: str,
    *,
    notes: str | None = None,
    repo: str = DEFAULT_REPO,
    prev_source_path: Path | None = None,
    release_date: str | None = None,
) -> dict:
    """Build a Feather + SideStore + AltStore Source v2 JSON dictionary."""
    meta = extract_ipa_metadata(ipa_path)
    repo_slug = repo.strip().strip("/") or DEFAULT_REPO
    owner = repo_slug.split("/", 1)[0]
    icon_url = (
        f"https://raw.githubusercontent.com/{repo_slug}/main/"
        "packaging/icons/hicolor/512x512/apps/horizon.png"
    )
    website_url = f"https://github.com/{repo_slug}"
    iso_date = release_date or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    version_notes = (
        notes.strip()
        if notes and notes.strip()
        else f"Horizon iOS {meta['version']} (build {meta['buildVersion']})."
    )

    new_version = {
        "version": meta["version"],
        "buildVersion": meta["buildVersion"],
        "date": iso_date,
        "localizedDescription": version_notes,
        "downloadURL": download_url.strip(),
        "size": meta["size"],
        "minOSVersion": meta["minOSVersion"],
    }

    versions: list[dict] = [new_version]
    seen_keys: set[tuple[str, str]] = {(meta["version"], meta["buildVersion"])}
    for prev in _load_previous_versions(prev_source_path, meta["bundleIdentifier"]):
        pv = str(prev.get("version") or "").strip()
        pb = str(prev.get("buildVersion") or "").strip()
        if not pv:
            continue
        key = (pv, pb)
        if key in seen_keys:
            continue
        seen_keys.add(key)
        versions.append(prev)
        if len(versions) >= MAX_VERSION_HISTORY:
            break

    privacy = dict(meta["privacy"])
    privacy.setdefault(
        "NSMotionUsageDescription",
        "The gyroscope can turn the camera when gyro aiming is on.",
    )
    privacy.setdefault(
        "NSLocalNetworkUsageDescription",
        "Horizon finds and joins games on your local network.",
    )

    bundle_id = meta["bundleIdentifier"]
    app_entry = {
        "name": meta["name"],
        "bundleIdentifier": bundle_id,
        "developerName": owner,
        "subtitle": "Minecraft: Java Edition 26.3 in Rust (No JIT)",
        "localizedDescription": (
            "Unofficial, experimental, vibe-coded (AI-built) iOS port of Horizon "
            "(Minecraft: Java Edition 26.3 rewritten in Rust with wgpu/Metal — no JVM, no JIT). "
            "Expect bugs and rough edges; back up your worlds before playing. Includes a native "
            "Pre-Launcher, Bedrock-style touch controls, GameController, and hardware "
            "keyboard+mouse support. Bring your own Minecraft: Java Edition assets."
        ),
        "iconURL": icon_url,
        "tintColor": DEFAULT_TINT_COLOR,
        "category": "games",
        "screenshotURLs": [],
        # Legacy top-level fields kept alongside `versions` for older AltStore/SideStore clients.
        "version": new_version["version"],
        "versionDate": new_version["date"],
        "versionDescription": new_version["localizedDescription"],
        "downloadURL": new_version["downloadURL"],
        "size": new_version["size"],
        "versions": versions,
        "appPermissions": {
            "entitlements": list(DEFAULT_ENTITLEMENTS),
            "privacy": privacy,
        },
    }

    return {
        "name": "Horizon iOS",
        "identifier": f"{bundle_id}.repo",
        "subtitle": "Minecraft: Java Edition 26.3 in Rust for iOS (No JIT)",
        "description": (
            "OTA repository for Horizon iOS — an unofficial, experimental, vibe-coded (AI-built) "
            "iOS port of Horizon. Compatible with Feather, SideStore, and AltStore."
        ),
        "iconURL": icon_url,
        "website": website_url,
        "tintColor": DEFAULT_TINT_COLOR,
        "featuredApps": [bundle_id],
        "apps": [app_entry],
        "news": [],
    }


def write_source_manifest(out_path: Path, manifest: dict) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = out_path.with_name(f".{out_path.name}.tmp.{os.getpid()}")
    tmp_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp_path.replace(out_path)


class IosOtaSourceTests(unittest.TestCase):
    def _make_synthetic_ipa(
        self,
        path: Path,
        *,
        short_version: str = "0.20261122.845",
        build_version: str = "202611220845",
        bundle_id: str = DEFAULT_BUNDLE_ID,
        binary_plist: bool = True,
    ) -> Path:
        plist_data = {
            "CFBundleDisplayName": "Horizon",
            "CFBundleIdentifier": bundle_id,
            "CFBundleShortVersionString": short_version,
            "CFBundleVersion": build_version,
            "MinimumOSVersion": "15.0",
            "NSMotionUsageDescription": "The gyroscope can turn the camera when gyro aiming is on.",
            "NSLocalNetworkUsageDescription": "Horizon finds and joins games on your local network.",
        }
        fmt = plistlib.FMT_BINARY if binary_plist else plistlib.FMT_XML
        encoded = plistlib.dumps(plist_data, fmt=fmt)
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("Payload/Horizon.app/Info.plist", encoded)
            zf.writestr("Payload/Horizon.app/horizon-ios", b"\xCF\xFA\xED\xFE" + b"\x00" * 1024)
        return path

    def test_generate_source_v2_schema_and_entitlements(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ipa = self._make_synthetic_ipa(Path(tmp) / "Horizon.ipa")
            dl = "https://github.com/nggurbanov/horizon-ios/releases/download/ios-latest/Horizon.ipa"
            manifest = build_source_manifest(
                ipa,
                dl,
                notes="Added OTA updates",
                release_date="2026-11-22T05:45:00Z",
            )

            self.assertEqual(manifest["name"], "Horizon iOS")
            self.assertEqual(manifest["identifier"], "io.github.nggurbanov.horizon-ios.repo")
            self.assertEqual(manifest["tintColor"], "33bd66")
            self.assertEqual(manifest["featuredApps"], [DEFAULT_BUNDLE_ID])
            self.assertEqual(manifest["news"], [])
            self.assertEqual(
                manifest["iconURL"],
                "https://raw.githubusercontent.com/nggurbanov/horizon-ios/main/packaging/icons/hicolor/512x512/apps/horizon.png",
            )
            self.assertEqual(manifest["website"], "https://github.com/nggurbanov/horizon-ios")

            self.assertEqual(len(manifest["apps"]), 1)
            app = manifest["apps"][0]
            self.assertEqual(app["bundleIdentifier"], DEFAULT_BUNDLE_ID)
            self.assertEqual(app["version"], "0.20261122.845")
            self.assertEqual(app["versionDate"], "2026-11-22T05:45:00Z")
            self.assertEqual(app["versionDescription"], "Added OTA updates")
            self.assertEqual(app["downloadURL"], dl)
            self.assertEqual(app["size"], ipa.stat().st_size)

            self.assertEqual(len(app["versions"]), 1)
            v0 = app["versions"][0]
            self.assertEqual(v0["version"], "0.20261122.845")
            self.assertEqual(v0["buildVersion"], "202611220845")
            self.assertEqual(v0["date"], "2026-11-22T05:45:00Z")
            self.assertEqual(v0["localizedDescription"], "Added OTA updates")
            self.assertEqual(v0["downloadURL"], dl)
            self.assertEqual(v0["size"], ipa.stat().st_size)
            self.assertEqual(v0["minOSVersion"], "15.0")

            perms = app["appPermissions"]
            self.assertEqual(
                perms["entitlements"],
                ["com.apple.developer.kernel.increased-memory-limit"],
            )
            self.assertIn("NSMotionUsageDescription", perms["privacy"])
            self.assertIn("NSLocalNetworkUsageDescription", perms["privacy"])

    def test_version_history_deduplication_and_cap(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            prev_path = tmp_dir / "source.json"
            dl = "https://github.com/nggurbanov/horizon-ios/releases/download/ios-latest/Horizon.ipa"

            # Seed 6 distinct older versions; newest must replace duplicate and cap at 5 total.
            for idx in range(1, 7):
                ipa = self._make_synthetic_ipa(
                    tmp_dir / f"Horizon-{idx}.ipa",
                    short_version=f"0.2026112{idx}.{800 + idx}",
                    build_version=f"2026112{idx}080{idx}",
                    binary_plist=(idx % 2 == 0),
                )
                m = build_source_manifest(
                    ipa,
                    dl,
                    notes=f"Release {idx}",
                    prev_source_path=prev_path if prev_path.exists() else None,
                    release_date=f"2026-11-2{idx}T08:0{idx}:00Z",
                )
                write_source_manifest(prev_path, m)

            data = json.loads(prev_path.read_text(encoding="utf-8"))
            versions = data["apps"][0]["versions"]
            self.assertEqual(len(versions), MAX_VERSION_HISTORY)
            self.assertEqual(
                [v["version"] for v in versions],
                [
                    "0.20261126.806",
                    "0.20261125.805",
                    "0.20261124.804",
                    "0.20261123.803",
                    "0.20261122.802",
                ],
            )

            # Re-publishing the exact same (version, buildVersion) updates entry 0 without duplicating.
            dup_ipa = self._make_synthetic_ipa(
                tmp_dir / "Horizon-dup.ipa",
                short_version="0.20261126.806",
                build_version="202611260806",
            )
            m_dup = build_source_manifest(
                dup_ipa,
                dl,
                notes="Release 6 refreshed",
                prev_source_path=prev_path,
                release_date="2026-11-26T09:00:00Z",
            )
            versions_dup = m_dup["apps"][0]["versions"]
            self.assertEqual(len(versions_dup), MAX_VERSION_HISTORY)
            self.assertEqual(versions_dup[0]["localizedDescription"], "Release 6 refreshed")
            self.assertEqual(
                len({(v["version"], v["buildVersion"]) for v in versions_dup}),
                MAX_VERSION_HISTORY,
            )

    def test_short_version_derivation(self) -> None:
        self.assertEqual(short_version_from_build_number("202611220845"), "0.20261122.845")
        self.assertEqual(short_version_from_build_number("202611220000"), "0.20261122.0")
        self.assertEqual(short_version_from_build_number("202611220007"), "0.20261122.7")
        self.assertEqual(short_version_from_build_number("202611221420"), "0.20261122.1420")


def run_self_tests() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(IosOtaSourceTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, help="Path to Horizon.ipa")
    parser.add_argument("--download-url", help="Public HTTPS URL of Horizon.ipa")
    parser.add_argument("--out", type=Path, help="Destination path for source.json")
    parser.add_argument("--notes", default="", help="Release notes / changelog text")
    parser.add_argument("--repo", default=DEFAULT_REPO, help="GitHub owner/repo slug")
    parser.add_argument(
        "--prev-source",
        type=Path,
        default=None,
        help="Optional previous source.json to retain up to 5 recent version entries",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run built-in unit tests and exit",
    )
    args = parser.parse_args(argv)

    if args.self_test:
        return run_self_tests()

    if not args.ipa or not args.download_url or not args.out:
        parser.error("--ipa, --download-url, and --out are required unless --self-test is set")

    manifest = build_source_manifest(
        args.ipa,
        args.download_url,
        notes=args.notes,
        repo=args.repo,
        prev_source_path=args.prev_source,
    )
    write_source_manifest(args.out, manifest)
    app = manifest["apps"][0]
    v0 = app["versions"][0]
    print(
        f"Wrote {args.out} ({app['bundleIdentifier']} v{v0['version']} "
        f"build {v0['buildVersion']}, {v0['size']} bytes, {len(app['versions'])} version(s))"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
