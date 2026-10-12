# SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import copy
import datetime
import hashlib
import importlib.util
from pathlib import Path
import unittest
import sys
import tempfile
import plistlib
from unittest import mock

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("sign_mac_app", Path(__file__).with_name("sign-mac-app.py"))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.certificate = b"synthetic test certificate"
        self.digest = hashlib.sha1(self.certificate).hexdigest().upper()
        self.profile = {
            "Platform": ["OSX"],
            "ProvisionsAllDevices": True,
            "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=30),
            "DeveloperCertificates": [self.certificate],
            "ApplicationIdentifierPrefix": ["EXAMPLETEAM"],
            "Entitlements": {
                "com.apple.developer.team-identifier": "EXAMPLETEAM",
                "com.apple.application-identifier": "EXAMPLETEAM.ai.tokenstat.tokenstat",
                "keychain-access-groups": ["EXAMPLETEAM.*"],
                "com.apple.security.application-groups": ["group.ai.tokenstat.tokenstat"],
            },
        }

    def test_resolves_only_required_entitlements(self):
        result = signing.profile_entitlements(self.profile, self.digest)
        self.assertEqual(result, {
            "com.apple.application-identifier": "EXAMPLETEAM.ai.tokenstat.tokenstat",
            "com.apple.developer.team-identifier": "EXAMPLETEAM",
            "keychain-access-groups": ["EXAMPLETEAM.ai.tokenstat.tokenstat"],
            "com.apple.security.application-groups": ["group.ai.tokenstat.tokenstat"],
        })

    def test_rejects_wrong_platform_distribution_expiry_and_certificate(self):
        for key, value in [
            ("Platform", ["iOS"]),
            ("ProvisionsAllDevices", False),
            ("ExpirationDate", datetime.datetime(2000, 1, 1)),
            ("DeveloperCertificates", [b"another certificate"]),
            ("ApplicationIdentifierPrefix", []),
        ]:
            with self.subTest(key=key):
                profile = copy.deepcopy(self.profile)
                profile[key] = value
                with self.assertRaises(ValueError):
                    signing.profile_entitlements(profile, self.digest)

    def test_rejects_other_app_and_keychain_group(self):
        for key, value in [
            ("com.apple.application-identifier", "EXAMPLETEAM.other.app"),
            ("keychain-access-groups", ["EXAMPLETEAM.other.app"]),
            ("com.apple.developer.team-identifier", ""),
        ]:
            with self.subTest(key=key):
                profile = copy.deepcopy(self.profile)
                profile["Entitlements"][key] = value
                with self.assertRaises(ValueError):
                    signing.profile_entitlements(profile, self.digest)

    def test_allows_exact_group_and_authorized_wildcard_app_id(self):
        self.profile["Entitlements"]["com.apple.application-identifier"] = "EXAMPLETEAM.*"
        self.profile["Entitlements"]["keychain-access-groups"] = ["EXAMPLETEAM.ai.tokenstat.tokenstat"]
        signing.profile_entitlements(self.profile, self.digest)


class MatchIdentityTests(unittest.TestCase):
    def setUp(self):
        self.candidates = [
            ("AABBCC" * 6 + "AABB", "Developer ID Application: Example One (TEAMONE)"),
            ("DDEEFF" * 6 + "DDEE", "Developer ID Application: Example Two (TEAMTWO)"),
        ]

    def test_trims_a_pasted_identity(self):
        [match] = signing.match_identity(
            self.candidates, "Developer ID Application: Example One (TEAMONE)\n"
        )
        self.assertEqual(match[1], "Developer ID Application: Example One (TEAMONE)")

    def test_matches_digest_case_insensitively(self):
        [match] = signing.match_identity(self.candidates, ("aabbcc" * 6 + "aabb"))
        self.assertEqual(match[0], "AABBCC" * 6 + "AABB")

    def test_empty_identity_keeps_everything(self):
        self.assertEqual(signing.match_identity(self.candidates, ""), self.candidates)
        self.assertEqual(signing.match_identity(self.candidates, None), self.candidates)

    def test_unknown_identity_matches_nothing(self):
        self.assertEqual(signing.match_identity(self.candidates, "Nobody"), [])


class OptionalSigningTests(unittest.TestCase):
    def test_available_identity_signs_but_check_only_never_mutates_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Tokenstat.app"
            (app / "Contents/Resources").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": signing.BUNDLE_ID}))
            (app / "Contents/Resources/tokenstat-hostd").write_text("fixture")
            identity = '  1) ' + 'A' * 40 + ' "Developer ID Application: Fixture (TEAM)"'
            for check_only in (True, False):
                argv = ["sign-mac-app.py", str(app), "--optional"] + (["--check-only"] if check_only else [])
                with self.subTest(check_only=check_only), mock.patch.object(sys, "argv", argv), \
                     mock.patch.dict(signing.os.environ, {}, clear=True), \
                     mock.patch.object(Path, "home", return_value=root), \
                     mock.patch.object(signing.subprocess, "check_output", return_value=identity), \
                     mock.patch.object(signing.subprocess, "run") as run:
                    signing.main()
                    self.assertEqual(run.call_count, 0 if check_only else 3)


if __name__ == "__main__":
    unittest.main()
