"""Unit tests for tools/ios_ota_source.py (AltStore / Feather Source v2 generator)."""

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from ios_ota_source import IosOtaSourceTests  # noqa: E402,F401

if __name__ == "__main__":
    unittest.main()
