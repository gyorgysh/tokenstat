# SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import copy
import datetime
import hashlib
import importlib.util
from pathlib import Path
import unittest
import sys

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
            },
        }

    def test_resolves_only_required_entitlements(self):
        result = signing.profile_entitlements(self.profile, self.digest)
        self.assertEqual(result, {
            "com.apple.application-identifier": "EXAMPLETEAM.ai.tokenstat.tokenstat",
            "com.apple.developer.team-identifier": "EXAMPLETEAM",
            "keychain-access-groups": ["EXAMPLETEAM.ai.tokenstat.tokenstat"],
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


if __name__ == "__main__":
    unittest.main()
