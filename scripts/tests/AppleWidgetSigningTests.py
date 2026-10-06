# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run with python3 scripts/tests/AppleWidgetSigningTests.py; no signing identity required."""
import datetime
import hashlib
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("sign_mac_app", Path(__file__).resolve().parents[1] / "sign-mac-app.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class WidgetSigningTests(unittest.TestCase):
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
