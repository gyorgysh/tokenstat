#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Sign the Mac app with its biometric Keychain entitlements and Developer ID profile.

TOKENSTAT_MAC_PROFILE selects a downloaded .provisionprofile. Otherwise search
Xcode's installed profiles. CI supplies DEVELOPER_ID_PROFILE_BASE64 as a secret.
No profile or certificate is stored in the repository.
"""

import argparse
import base64
import datetime
import fnmatch
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

BUNDLE_ID = "ai.tokenstat.tokenstat"
ROOT = Path(__file__).resolve().parent.parent


def profile_entitlements(profile, certificate):
    """Validate authorization before modifying the app bundle."""
    if "OSX" not in profile.get("Platform", []):
        raise ValueError("The profile must be for macOS.")
    if not profile.get("ProvisionsAllDevices"):
        raise ValueError("Use a Developer ID distribution profile, not a development or App Store profile.")
    if profile.get("ExpirationDate", datetime.datetime.min) <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
        raise ValueError("The provisioning profile has expired.")
    certificates = {hashlib.sha1(data).hexdigest().upper() for data in profile.get("DeveloperCertificates", [])}
    if certificate.upper() not in certificates:
        raise ValueError("The profile does not authorize this Developer ID Application certificate.")
    allowed = profile.get("Entitlements", {})
    team = allowed.get("com.apple.developer.team-identifier", "")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    if not team or not prefixes:
        raise ValueError("The profile is missing its team or App ID prefix.")
    app_id = prefixes[0] + "." + BUNDLE_ID
    if not fnmatch.fnmatchcase(app_id, allowed.get("com.apple.application-identifier", "")):
        raise ValueError("The profile does not authorize " + BUNDLE_ID + ".")
    if not any(fnmatch.fnmatchcase(app_id, group) for group in allowed.get("keychain-access-groups", [])):
        raise ValueError("The profile does not authorize the app's Keychain access group.")
    template = (ROOT / "apps/mac/Entitlements/macOS.entitlements").read_text()
    template = template.replace("$(AppIdentifierPrefix)", prefixes[0] + ".").replace("$(DEVELOPMENT_TEAM)", team)
    return plistlib.loads(template.encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--identity", help="Developer ID Application certificate name or SHA-1")
    parser.add_argument("--check-only", action="store_true", help="Validate signing inputs without changing the app")
    parser.add_argument("--optional", action="store_true", help="Allow a local debug build without a signing profile")
    args = parser.parse_args()
    with (args.app / "Contents/Info.plist").open("rb") as stream:
        if plistlib.load(stream).get("CFBundleIdentifier") != BUNDLE_ID:
            raise ValueError("Expected the tokenstat app bundle.")
    identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
    candidates = re.findall(r'\b([0-9A-Fa-f]{40})\s+"(Developer ID Application: [^"]+)"', identities)
    if args.identity:
        candidates = [(digest, name) for digest, name in candidates if args.identity.upper() == digest.upper() or args.identity == name]
    with tempfile.TemporaryDirectory(prefix="tokenstat-sign-") as temporary:
        temporary = Path(temporary)
        explicit = os.environ.get("TOKENSTAT_MAC_PROFILE")
        encoded = os.environ.get("DEVELOPER_ID_PROFILE_BASE64")
        if explicit and encoded:
            raise ValueError("Set only one of TOKENSTAT_MAC_PROFILE and DEVELOPER_ID_PROFILE_BASE64.")
        if encoded:
            path = temporary / "download.provisionprofile"
            path.write_bytes(base64.b64decode("".join(encoded.split()), validate=True))
            profiles = [path]
        elif explicit:
            profiles = [Path(explicit).expanduser()]
        else:
            profiles = []
            for folder in ("Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"):
                profiles.extend(sorted((Path.home() / folder).glob("*.provisionprofile")))
        selected = None
        for path in profiles:
            try:
                profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(path)], stderr=subprocess.DEVNULL))
                refusal = None
                for digest, _ in candidates:
                    try:
                        entitlements = profile_entitlements(profile, digest)
                        selected = (path, digest, entitlements)
                        break
                    except ValueError as error:
                        refusal = error
                if not selected and refusal and (explicit or encoded):
                    raise refusal
                if selected:
                    break
            except (ValueError, subprocess.CalledProcessError):
                if explicit or encoded:
                    raise
        if not selected:
            message = ("No matching Developer ID certificate/profile for ai.tokenstat.tokenstat. "
                       "Download its Developer ID provisioning profile and set TOKENSTAT_MAC_PROFILE to its path. "
                       "CI requires the DEVELOPER_ID_PROFILE_BASE64 release secret.")
            if args.optional and not (explicit or encoded or args.identity):
                print(message + " Debug build remains unsigned; biometric vault unlock is unavailable.")
                return
            raise ValueError(message)
        profile_path, digest, entitlements = selected
        if args.check_only:
            print("Developer ID certificate, profile and Keychain entitlements match.")
            return
        helper = args.app / "Contents/Resources/tokenstat-hostd"
        if not helper.is_file():
            raise ValueError("No tokenstat-hostd in the app bundle.")
        entitlement_path = temporary / "entitlements.plist"
        entitlement_path.write_bytes(plistlib.dumps(entitlements))
        shutil.copyfile(profile_path, args.app / "Contents/embedded.provisionprofile")
        sign = ["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", digest]
        subprocess.run(sign + [str(helper)], check=True)
        # Sign nested code before the outer app; only the app gets the restricted
        # Keychain entitlements. --deep must never propagate them to frameworks.
        subprocess.run(sign + ["--deep", str(args.app)], check=True)
        subprocess.run(sign + ["--entitlements", str(entitlement_path), str(args.app)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(args.app)], check=True)
        actual = plistlib.loads(subprocess.check_output(["codesign", "-d", "--entitlements", "-", "--xml", str(args.app)], stderr=subprocess.DEVNULL))
        if any(actual.get(key) != value for key, value in entitlements.items()):
            raise ValueError("The signed app is missing its required Keychain entitlements.")
        print("Signed tokenstat with its Developer ID profile and biometric Keychain entitlements.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
