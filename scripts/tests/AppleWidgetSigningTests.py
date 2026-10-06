# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run with python3 scripts/tests/AppleWidgetSigningTests.py; no signing identity required."""
import datetime
import hashlib
import importlib.util
from pathlib import Path
import unittest
import struct
import zlib

spec = importlib.util.spec_from_file_location("sign_mac_app", Path(__file__).resolve().parents[1] / "sign-mac-app.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
icon_spec = importlib.util.spec_from_file_location("apple_icon", Path(__file__).resolve().parents[1] / "apple-icon.py")
icons = importlib.util.module_from_spec(icon_spec)
icon_spec.loader.exec_module(icons)


class WidgetSigningTests(unittest.TestCase):
    def test_watch_icon_is_store_ready(self):
        path = signing.ROOT / "apps/mac/WatchResources/Assets.xcassets/AppIcon.appiconset/app-icon.png"
        icons.validate_store_icon(path.read_bytes(), size=1024)

    def test_alpha_and_palette_transparency_are_rejected(self):
        def chunk(kind, payload):
            return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
        def png(color, transparent=False):
            return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1024, 1024, 8, color, 0, 0, 0)) + (chunk(b"tRNS", b"\x00") if transparent else b"") + chunk(b"IEND", b"")
        icons.validate_store_icon(png(2), size=1024)
        icons.validate_store_icon(png(2)[:8] + chunk(b"CgBI", b"\x40\xa0\x60\x82") + png(2)[8:], size=1024)
        for color, transparent in [(6, False), (4, False), (3, True)]:
            with self.assertRaises(ValueError):
                icons.validate_store_icon(png(color, transparent), size=1024)

    def profile(self, bundle_id):
        certificate = b"fixture-certificate"
        digest = hashlib.sha1(certificate).hexdigest().upper()
        return {
            "Platform": ["OSX"],
            "ProvisionsAllDevices": True,
            "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=1),
            "DeveloperCertificates": [certificate],
            "ApplicationIdentifierPrefix": ["FIXTURE"],
            "Entitlements": {
                "com.apple.developer.team-identifier": "FIXTURE",
                "com.apple.application-identifier": "FIXTURE." + bundle_id,
                "keychain-access-groups": ["FIXTURE.ai.tokenstat.tokenstat"],
                "com.apple.security.application-groups": ["group.ai.tokenstat.tokenstat"],
            },
        }, digest

    def test_corrupt_or_truncated_icon_metadata_is_rejected(self):
        data = (signing.ROOT / "apps/mac/WatchResources/Assets.xcassets/AppIcon.appiconset/app-icon.png").read_bytes()
        corrupt = bytearray(data)
        corrupt[29] ^= 1  # IHDR checksum
        for invalid in (data[:-12], data[:-1], data + b"trailing", bytes(corrupt)):
            with self.assertRaises(ValueError):
                icons.validate_store_icon(invalid, size=1024)

    def test_app_and_extension_have_distinct_entitlements(self):
        profile, digest = self.profile(signing.BUNDLE_ID)
        app = signing.profile_entitlements(profile, digest)
        self.assertIn("keychain-access-groups", app)
        self.assertIn("com.apple.security.application-groups", app)
        profile, digest = self.profile(signing.WIDGET_BUNDLE_ID)
        widget = signing.profile_entitlements(profile, digest, signing.WIDGET_BUNDLE_ID)
        self.assertTrue(widget["com.apple.security.app-sandbox"])
        self.assertNotIn("keychain-access-groups", widget)
        self.assertEqual(widget["com.apple.application-identifier"], "FIXTURE." + signing.WIDGET_BUNDLE_ID)

    def test_missing_shared_group_is_rejected(self):
        for bundle_id in [signing.BUNDLE_ID, signing.WIDGET_BUNDLE_ID]:
            profile, digest = self.profile(bundle_id)
            profile["Entitlements"].pop("com.apple.security.application-groups")
            with self.assertRaisesRegex(ValueError, "shared widget App Group"):
                signing.profile_entitlements(profile, digest, bundle_id)

    def test_app_profile_cannot_sign_extension(self):
        profile, digest = self.profile(signing.BUNDLE_ID)
        with self.assertRaisesRegex(ValueError, "does not authorize"):
            signing.profile_entitlements(profile, digest, signing.WIDGET_BUNDLE_ID)

    def test_certificate_must_match(self):
        profile, _ = self.profile(signing.WIDGET_BUNDLE_ID)
        with self.assertRaisesRegex(ValueError, "certificate"):
            signing.profile_entitlements(profile, "WRONG", signing.WIDGET_BUNDLE_ID)


if __name__ == "__main__":
    unittest.main()
