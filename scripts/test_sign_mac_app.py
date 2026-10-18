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


class DebugLibrarySigningTests(unittest.TestCase):
    def test_profiled_debug_app_and_widget_sign_libraries_before_their_bundles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Tokenstat.app"
            widget = app / "Contents/PlugIns/TokenstatWidgets.appex"
            libraries = []
            for bundle, identifier in [(app, signing.BUNDLE_ID), (widget, signing.WIDGET_BUNDLE_ID)]:
                (bundle / "Contents/MacOS").mkdir(parents=True)
                (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
                for name in [bundle.stem + ".debug.dylib", "__preview.dylib"]:
                    library = bundle / "Contents/MacOS" / name
                    library.write_bytes(b"linker-signed fixture")
                    libraries.append((bundle, library))
            (app / "Contents/Resources").mkdir()
            (app / "Contents/Resources/tokenstat-hostd").write_bytes(b"fixture")
            app_profile = root / "app.provisionprofile"
            widget_profile = root / "widget.provisionprofile"
            app_profile.write_bytes(b"app profile")
            widget_profile.write_bytes(b"widget profile")
            fixture = ProfileTests()
            fixture.setUp()
            widget_authorization = copy.deepcopy(fixture.profile)
            widget_authorization["Entitlements"]["com.apple.application-identifier"] = "EXAMPLETEAM." + signing.WIDGET_BUNDLE_ID
            signed = []

            def run(command, **kwargs):
                if "--sign" in command:
                    signed.append(command)

            def output(command, **kwargs):
                if command[0] == "security" and command[1] == "find-identity":
                    return '1) ' + fixture.digest + ' "Developer ID Application: Fixture (EXAMPLETEAM)"'
                if command[0] == "security":
                    return plistlib.dumps(fixture.profile if command[-1] == str(app_profile) else widget_authorization)
                if "--entitlements" in command:
                    return plistlib.dumps(signing.profile_entitlements(fixture.profile, fixture.digest))
                # A library keeps its old ad-hoc signature until explicitly signed.
                if any(str(library) == command[-1] for _, library in libraries):
                    if not any(call[-1] == command[-1] for call in signed):
                        return "TeamIdentifier=not set\n"
                return "TeamIdentifier=EXAMPLETEAM\n"

            with mock.patch.object(sys, "argv", ["sign-mac-app.py", str(app)]), \
                 mock.patch.dict(signing.os.environ, {
                     "TOKENSTAT_MAC_PROFILE": str(app_profile),
                     "TOKENSTAT_MAC_WIDGET_PROFILE": str(widget_profile),
                 }, clear=True), \
                 mock.patch.object(signing.subprocess, "check_output", side_effect=output), \
                 mock.patch.object(signing.subprocess, "run", side_effect=run):
                signing.main()

            paths = [command[-1] for command in signed]
            for bundle, library in libraries:
                self.assertLess(paths.index(str(library)), paths.index(str(bundle)))
                command = signed[paths.index(str(library))]
                self.assertNotIn("--entitlements", command)
            widget_command = signed[paths.index(str(widget))]
            self.assertIn("widget-entitlements-0.plist", widget_command[-2])

    def test_signature_verification_alone_does_not_accept_a_different_or_missing_library_team(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Tokenstat.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            library = app / "Contents/MacOS/Tokenstat.debug.dylib"
            library.touch()
            for team in ("OTHERTEAM", "not set"):
                with self.subTest(team=team), \
                     mock.patch.object(signing.subprocess, "run"), \
                     mock.patch.object(signing.subprocess, "check_output", side_effect=[
                         "TeamIdentifier=EXAMPLETEAM\n", "TeamIdentifier=" + team + "\n",
                     ]):
                    with self.assertRaises(ValueError):
                        signing.verify_library_teams(app)


if __name__ == "__main__":
    unittest.main()
