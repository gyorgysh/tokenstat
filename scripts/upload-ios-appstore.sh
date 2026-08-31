#!/usr/bin/env bash
#
# Build a TestFlight IPA from this checkout and upload it to App Store Connect.
# Does not submit for App Review, and does not change listing metadata.
#
# One command is the whole local TestFlight path: FFI, archive, export, IPA
# checks, upload. Credentials never enter the repository and must not appear
# on the terminal: no team id, key id, issuer, person name, or absolute path.
#
# Usage:
#   scripts/upload-ios-appstore.sh
#   scripts/upload-ios-appstore.sh --bump
#   scripts/upload-ios-appstore.sh --skip-ffi
#   scripts/upload-ios-appstore.sh --no-upload
#   scripts/upload-ios-appstore.sh --check dist/ios/export-<ver>-<build>/Tokenstat.ipa
#   scripts/upload-ios-appstore.sh --upload-only dist/ios/export-<ver>-<build>/Tokenstat.ipa
#   scripts/upload-ios-appstore.sh dist/ios/export-<ver>-<build>/Tokenstat.ipa
#
# The archive signs with Apple Development on purpose. Apple Distribution
# at archive time fails, and the export re-signs for the store.
#
# Credentials, never flags, never tracked files:
#   ~/.appstoreconnect/issuer_id
#   ~/.appstoreconnect/key_id            if more than one .p8 is installed
#   ~/.appstoreconnect/private_keys/     AuthKey_<id>.p8
#   ASC_ISSUER_ID, ASC_KEY_ID            override those files
#   ASC_PRIVATE_KEY_BASE64               CI: the .p8, base64, torn down on exit
#   ASC_PRIVATE_KEY_PATH                 copy an existing .p8 into a temp HOME
#   DEVELOPMENT_TEAM                     optional; default is the signing identity
#   TOKENSTAT_FFI_PLATFORMS              default "macos ios sim"
#
# A GUI archive (Product > Archive) has no team and cannot be exported. Use
# this script.

# Refuse inherited xtrace before anything else, then keep it off. Credentials
# and signing identities must never reach the terminal via `set -x`.
if [[ "$-" == *x* ]]; then
    echo "this script refuses xtrace so credentials cannot leak to the terminal" >&2
    exit 2
fi

set -euo pipefail
set +o xtrace
umask 077

if [ "$(uname -s)" != "Darwin" ]; then
    echo "this script only runs on macOS" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ORIG_HOME="${HOME}"

BUNDLE_ID="ai.tokenstat.tokenstat"
PROJECT_YML="apps/mac/project.yml"

usage() {
    cat <<'EOF'
Build a TestFlight IPA from this checkout and upload it to App Store Connect.

  scripts/upload-ios-appstore.sh
  scripts/upload-ios-appstore.sh --bump
  scripts/upload-ios-appstore.sh --no-upload
  scripts/upload-ios-appstore.sh --upload-only <relative/path.ipa>

Does not submit for App Review. Credentials come from ~/.appstoreconnect or
the environment, never from flags or files in the repository. Output is
version, build, check names, and a delivery id. No team, key, issuer, or
absolute path.

Options:
  --bump          Increment CURRENT_PROJECT_VERSION in project.yml first
  --skip-ffi      Reuse the xcframework already built
  --no-upload     Archive, export, and check, then stop
  --check PATH    Check an already-exported IPA (repo-relative), do not upload
  --upload-only   Upload an IPA that is already exported (repo-relative path)
  --self-test     Redact and parse checks only, no Apple, no build
  -h, --help
EOF
}

helper() {
    python3 /dev/fd/3 "$@" 3<<'PY'
import os, re, shutil, subprocess, sys, tempfile, zipfile, plistlib

def redact():
    text = sys.stdin.read()
    pairs = []
    for key, name in (
        ("UPLOAD_IOS_ROOT", "."),
        ("HOME", "~"),
        ("UPLOAD_IOS_TEAM", "<team>"),
        ("UPLOAD_IOS_KEY", "<key>"),
        ("UPLOAD_IOS_ISSUER", "<issuer>"),
    ):
        val = os.environ.get(key, "")
        if val:
            pairs.append((val, name))
    pairs.sort(key=lambda item: len(item[0]), reverse=True)
    for val, name in pairs:
        text = text.replace(val, name)
    text = re.sub(r"AuthKey_[A-Za-z0-9_-]+", "AuthKey_<id>", text)
    text = re.sub(
        r"Apple Development: [^(\n]+(?:\([^)]*\))?", "Apple Development", text
    )
    text = re.sub(
        r"Apple Distribution: [^(\n]+(?:\([^)]*\))?", "Apple Distribution", text
    )
    text = re.sub(
        r"Developer ID Application: [^(\n]+(?:\([^)]*\))?",
        "Developer ID Application",
        text,
    )
    sys.stdout.write(text)


def read_versions(path):
    text = open(path, encoding="utf-8").read()

    def grab(key):
        match = re.search(r'(?m)^\s*%s:\s*"([^"]+)"' % re.escape(key), text)
        if not match:
            raise SystemExit("missing %s" % key)
        return match.group(1)

    sys.stdout.write(grab("MARKETING_VERSION") + "\n")
    sys.stdout.write(grab("CURRENT_PROJECT_VERSION") + "\n")


def bump(path):
    text = open(path, encoding="utf-8").read()

    def repl(match):
        return match.group(1) + str(int(match.group(2)) + 1) + match.group(3)

    new, count = re.subn(
        r'(?m)^(\s*CURRENT_PROJECT_VERSION:\s*")(\d+)(")',
        repl,
        text,
        count=1,
    )
    if count != 1:
        raise SystemExit("could not bump CURRENT_PROJECT_VERSION")
    open(path, "w", encoding="utf-8").write(new)
    match = re.search(r'(?m)^\s*CURRENT_PROJECT_VERSION:\s*"(\d+)"', new)
    sys.stdout.write(match.group(1) + "\n")


def check_ipa(ipa, expect_ver, expect_build):
    errors = []

    def fail(name, detail=None):
        if detail:
            print("  fail %s (%s)" % (name, detail), file=sys.stderr)
        else:
            print("  fail %s" % name, file=sys.stderr)
        errors.append(name)

    tmp = tempfile.mkdtemp(prefix="ts-ipa-")
    try:
        with zipfile.ZipFile(ipa) as archive:
            archive.extractall(tmp)
        app = os.path.join(tmp, "Payload", "Tokenstat.app")
        info_path = os.path.join(app, "Info.plist")
        if not os.path.isfile(info_path):
            fail("bundle")
            raise SystemExit(1)
        with open(info_path, "rb") as handle:
            info = plistlib.load(handle)
        version = str(info.get("CFBundleShortVersionString") or "")
        build = str(info.get("CFBundleVersion") or "")
        bundle_id = str(info.get("CFBundleIdentifier") or "")
        if expect_ver and version != expect_ver:
            fail("version", "mismatch")
        elif not version:
            fail("version")
        if expect_build and build != expect_build:
            fail("build", "mismatch")
        elif not build:
            fail("build")
        if bundle_id != "ai.tokenstat.tokenstat":
            fail("bundle-id")
        xml = subprocess.check_output(
            ["codesign", "-d", "--entitlements", "-", "--xml", app],
            stderr=subprocess.DEVNULL,
        )
        ents = plistlib.loads(xml)
        aps = ents.get("aps-environment")
        if aps != "production":
            fail("production-push", aps or "missing")
        if ents.get("beta-reports-active") is not True:
            fail("testflight-flag")
        if ents.get("get-task-allow"):
            fail("get-task-allow")
        app_id = str(ents.get("application-identifier") or "")
        if not app_id.endswith(".ai.tokenstat.tokenstat"):
            fail("application-id")
        profile_path = os.path.join(app, "embedded.mobileprovision")
        if not os.path.isfile(profile_path):
            fail("profile")
        else:
            cms = subprocess.check_output(
                ["security", "cms", "-D", "-i", profile_path],
                stderr=subprocess.DEVNULL,
            )
            profile = plistlib.loads(cms)
            name = str(profile.get("Name") or "")
            if not name.startswith("iOS Team Store Provisioning Profile"):
                fail("store-profile")
            if "ProvisionedDevices" in profile:
                fail("development-devices")
        if not os.path.isfile(os.path.join(app, "PrivacyInfo.xcprivacy")):
            fail("privacy-manifest")
        signed = subprocess.run(
            ["codesign", "-dv", "--verbose=2", app],
            capture_output=True,
            text=True,
        )
        sig = (signed.stdout or "") + (signed.stderr or "")
        if "Authority=Apple Distribution" not in sig:
            fail("distribution-signature")
        if errors:
            raise SystemExit(1)
        print("  %s (%s)" % (version, build))
        print("  production push")
        print("  testflight profile")
        print("  privacy manifest")
        print("  distribution signature")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def upload_status():
    text = sys.stdin.read()
    uuid_match = re.search(
        r"Delivery UUID:\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})",
        text,
    )
    duplicate = bool(
        re.search(r"\bDUPLICATE\b", text)
        or re.search(r"already been uploaded", text, re.I)
    )
    succeeded = "UPLOAD SUCCEEDED" in text
    if succeeded and uuid_match:
        print("succeeded %s" % uuid_match.group(1))
    elif succeeded:
        print("succeeded")
    elif duplicate:
        print("duplicate")
    else:
        print("failed")
        raise SystemExit(1)


def self_test():
    os.environ["UPLOAD_IOS_ROOT"] = "/tmp/example-root"
    os.environ["HOME"] = "/tmp/example-home"
    os.environ["UPLOAD_IOS_TEAM"] = "ABCDEF1234"
    os.environ["UPLOAD_IOS_KEY"] = "KEYID12345"
    os.environ["UPLOAD_IOS_ISSUER"] = "00000000-1111-2222-3333-444444444444"
    sample = (
        "path /tmp/example-root/dist/ios/app.ipa\n"
        "home /tmp/example-home/.appstoreconnect/private_keys/AuthKey_KEYID12345.p8\n"
        "team ABCDEF1234.ai.tokenstat.tokenstat\n"
        "issuer 00000000-1111-2222-3333-444444444444\n"
        "Authority=Apple Development: Example Name (TEAMUSER)\n"
        "Delivery UUID: e5fa7e2c-e987-414e-aa60-f544523b3dfc\n"
        "UPLOAD SUCCEEDED with no errors\n"
    )
    import io
    from contextlib import redirect_stdout

    buf = io.StringIO()
    stdin = sys.stdin
    try:
        sys.stdin = io.StringIO(sample)
        with redirect_stdout(buf):
            redact()
    finally:
        sys.stdin = stdin
    out = buf.getvalue()
    leaks = [
        "/tmp/example-root",
        "/tmp/example-home",
        "ABCDEF1234",
        "KEYID12345",
        "00000000-1111-2222-3333-444444444444",
        "Example Name",
        "TEAMUSER",
        "AuthKey_KEYID",
    ]
    for leak in leaks:
        if leak in out:
            raise SystemExit("self-test leak: redaction missed a value")
    if "e5fa7e2c-e987-414e-aa60-f544523b3dfc" not in out:
        raise SystemExit("self-test: delivery id was stripped")
    if "UPLOAD SUCCEEDED" not in out:
        raise SystemExit("self-test: status was stripped")
    parsed = io.StringIO()
    sys.stdin = io.StringIO(out)
    with redirect_stdout(parsed):
        upload_status()
    status = parsed.getvalue().strip()
    if not status.startswith("succeeded"):
        raise SystemExit("self-test: upload status parse failed")
    print("self-test ok")


commands = {
    "redact": lambda: redact(),
    "versions": lambda: read_versions(sys.argv[2]),
    "bump": lambda: bump(sys.argv[2]),
    "check_ipa": lambda: check_ipa(sys.argv[2], sys.argv[3], sys.argv[4]),
    "upload_status": lambda: upload_status(),
    "self_test": lambda: self_test(),
}

cmd = sys.argv[1]
if cmd not in commands:
    raise SystemExit("unknown helper command")
commands[cmd]()
PY
}

redact() {
    UPLOAD_IOS_ROOT="$ROOT" \
    UPLOAD_IOS_TEAM="${TEAM:-}" \
    UPLOAD_IOS_KEY="${ASC_KEY_ID:-}" \
    UPLOAD_IOS_ISSUER="${ASC_ISSUER_ID:-}" \
    HOME="$ORIG_HOME" \
        helper redact
}

run_redacted() {
    local log_rel="$1"
    shift
    local raw st
    raw="$(mktemp)"
    st=0
    "$@" >"$raw" 2>&1 || st=$?
    mkdir -p "$(dirname "$ROOT/$log_rel")"
    redact <"$raw" >"$ROOT/$log_rel" || true
    rm -f "$raw"
    return "$st"
}

fail_from_log() {
    local message="$1"
    local log_rel="$2"
    echo "$message" >&2
    if [ -f "$ROOT/$log_rel" ]; then
        grep -E 'error:|ERROR:|fatal error|FAILED|failed' "$ROOT/$log_rel" \
            | tail -n 20 >&2 || true
        echo "details: $log_rel" >&2
    fi
    exit 1
}

is_rel_path() {
    case "$1" in
        /*)
            echo "paths must be relative to the repository; absolute paths are not accepted." >&2
            exit 2
            ;;
        *..*)
            echo "paths must not contain .." >&2
            exit 2
            ;;
    esac
}

team_from_cn_prefix() {
    local prefix="$1"
    local pem subject ou
    pem="$(security find-certificate -c "$prefix" -p 2>/dev/null)" || return 1
    subject="$(printf '%s' "$pem" | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null)" || return 1
    ou="$(printf '%s' "$subject" | tr ',' '\n' | awk -F= '{gsub(/^ /,"",$1); if ($1=="OU") {print $2; exit}}')"
    ou="$(printf '%s' "$ou" | tr -d '[:space:]')"
    case "$ou" in
        [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9])
            printf '%s' "$ou"
            return 0
            ;;
    esac
    return 1
}

resolve_team() {
    if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
        TEAM="$DEVELOPMENT_TEAM"
    else
        TEAM="$(team_from_cn_prefix "Apple Development" \
            || team_from_cn_prefix "Apple Distribution" \
            || team_from_cn_prefix "Developer ID Application" \
            || true)"
    fi
    case "${TEAM:-}" in
        [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
        *)
            echo "could not read the team id from a signing identity. Set DEVELOPMENT_TEAM." >&2
            exit 1
            ;;
    esac
}

load_credentials() {
    if [ -z "${ASC_ISSUER_ID:-}" ] && [ -f "$ORIG_HOME/.appstoreconnect/issuer_id" ]; then
        ASC_ISSUER_ID="$(tr -d '[:space:]' < "$ORIG_HOME/.appstoreconnect/issuer_id")"
    fi
    if [ -z "${ASC_KEY_ID:-}" ] && [ -f "$ORIG_HOME/.appstoreconnect/key_id" ]; then
        ASC_KEY_ID="$(tr -d '[:space:]' < "$ORIG_HOME/.appstoreconnect/key_id")"
    fi
    if [ -z "${ASC_KEY_ID:-}" ]; then
        local keys=() f
        shopt -s nullglob
        for f in "$ORIG_HOME/.appstoreconnect/private_keys"/AuthKey_*.p8; do
            keys+=("$f")
        done
        shopt -u nullglob
        if [ "${#keys[@]}" -eq 1 ]; then
            local base
            base="$(basename "${keys[0]}")"
            ASC_KEY_ID="${base#AuthKey_}"
            ASC_KEY_ID="${ASC_KEY_ID%.p8}"
        elif [ "${#keys[@]}" -gt 1 ]; then
            echo "multiple App Store Connect keys are installed. Set ASC_KEY_ID, or write the key id to ~/.appstoreconnect/key_id." >&2
            exit 2
        fi
    fi
    if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ]; then
        echo "App Store Connect credentials are missing. Need ~/.appstoreconnect/issuer_id and a key, or ASC_ISSUER_ID and ASC_KEY_ID." >&2
        exit 2
    fi
    case "$ASC_KEY_ID" in
        (*[!A-Za-z0-9_-]*) echo "ASC_KEY_ID contains unsupported characters." >&2; exit 2 ;;
    esac
    case "$ASC_ISSUER_ID" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
        *) echo "ASC_ISSUER_ID is not a UUID." >&2; exit 2 ;;
    esac
}

materialize_key() {
    TEMP_HOME="$(mktemp -d)"
    local key_dir key_path
    key_dir="$TEMP_HOME/.appstoreconnect/private_keys"
    mkdir -p "$key_dir"
    key_path="$key_dir/AuthKey_${ASC_KEY_ID}.p8"

    decode_base64() {
        if base64 -D </dev/null >/dev/null 2>&1; then
            base64 -D
        else
            base64 --decode
        fi
    }

    if [ -n "${ASC_PRIVATE_KEY_BASE64:-}" ]; then
        printf '%s' "$ASC_PRIVATE_KEY_BASE64" | tr -d '\r\n\t ' | decode_base64 > "$key_path"
    elif [ -n "${ASC_PRIVATE_KEY_PATH:-}" ]; then
        case "$ASC_PRIVATE_KEY_PATH" in
            /*) ;;
            *) echo "ASC_PRIVATE_KEY_PATH must be an absolute local path." >&2; exit 2 ;;
        esac
        if [ ! -f "$ASC_PRIVATE_KEY_PATH" ]; then
            echo "ASC_PRIVATE_KEY_PATH does not point to a file." >&2
            exit 1
        fi
        cp "$ASC_PRIVATE_KEY_PATH" "$key_path"
    else
        local src="$ORIG_HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
        if [ ! -f "$src" ]; then
            echo "no App Store Connect private key is installed for the selected key id." >&2
            exit 1
        fi
        cp "$src" "$key_path"
    fi
    unset ASC_PRIVATE_KEY_BASE64
    unset ASC_PRIVATE_KEY_PATH
    if [ ! -s "$key_path" ]; then
        echo "the App Store Connect private key is empty." >&2
        exit 1
    fi
    chmod 600 "$key_path"
    AUTH_KEY_PATH="$key_path"
}

write_export_options() {
    local dest="$1"
    python3 -c '
import plistlib, sys
team = sys.argv[1]
path = sys.argv[2]
data = {
    "method": "app-store-connect",
    "destination": "export",
    "teamID": team,
    "signingStyle": "automatic",
    "uploadSymbols": True,
    "manageAppVersionAndBuildNumber": False,
}
with open(path, "wb") as handle:
    plistlib.dump(data, handle)
' "$TEAM" "$dest"
}

read_project_versions() {
    local out
    out="$(helper versions "$PROJECT_YML")"
    VERSION="$(printf '%s\n' "$out" | sed -n '1p')"
    BUILD="$(printf '%s\n' "$out" | sed -n '2p')"
    if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
        echo "could not read MARKETING_VERSION and CURRENT_PROJECT_VERSION." >&2
        exit 1
    fi
}

bump_build() {
    local old="$BUILD"
    BUILD="$(helper bump "$PROJECT_YML")"
    echo "build $old -> $BUILD"
}

cleanup() {
    if [ -n "${TEMP_HOME:-}" ]; then
        rm -rf "$TEMP_HOME"
        TEMP_HOME=""
    fi
}
trap cleanup EXIT

BUMP=0
SKIP_FFI=0
NO_UPLOAD=0
UPLOAD_ONLY=0
CHECK_ONLY=0
SELF_TEST=0
IPA=""

while [ $# -gt 0 ]; do
    case "$1" in
        --bump) BUMP=1; shift ;;
        --skip-ffi) SKIP_FFI=1; shift ;;
        --no-upload) NO_UPLOAD=1; shift ;;
        --self-test) SELF_TEST=1; shift ;;
        --check)
            CHECK_ONLY=1
            shift
            if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
                IPA="$1"
                shift
            fi
            ;;
        --upload-only)
            UPLOAD_ONLY=1
            shift
            if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
                IPA="$1"
                shift
            fi
            ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *.ipa)
            UPLOAD_ONLY=1
            IPA="$1"
            shift
            ;;
        *)
            echo "unexpected argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ "$SELF_TEST" -eq 1 ]; then
    helper self_test
    exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ -z "$IPA" ]; then
        echo "--check needs a repository-relative IPA path." >&2
        exit 2
    fi
    is_rel_path "$IPA"
    if [ ! -f "$ROOT/$IPA" ]; then
        echo "IPA not found at the requested repository-relative path." >&2
        exit 1
    fi
    echo "checking IPA"
    helper check_ipa "$ROOT/$IPA" "" ""
    echo "ipa ok"
    exit 0
fi

if [ "$UPLOAD_ONLY" -eq 1 ]; then
    if [ -z "$IPA" ]; then
        echo "--upload-only needs a repository-relative IPA path." >&2
        exit 2
    fi
    if [ "$BUMP" -eq 1 ]; then
        echo "--bump cannot be combined with --upload-only." >&2
        exit 2
    fi
    if [ "$NO_UPLOAD" -eq 1 ]; then
        echo "--no-upload cannot be combined with --upload-only." >&2
        exit 2
    fi
    is_rel_path "$IPA"
    if [ ! -f "$ROOT/$IPA" ]; then
        echo "IPA not found at the requested repository-relative path." >&2
        exit 1
    fi
fi

load_credentials
materialize_key

if [ "$UPLOAD_ONLY" -eq 1 ]; then
    echo "checking IPA"
    helper check_ipa "$ROOT/$IPA" "" ""
    echo "uploading"
    mkdir -p "$ROOT/dist/ios"
    STATUS="$(
        HOME="$TEMP_HOME" xcrun altool \
            --upload-app \
            --type ios \
            --file "$ROOT/$IPA" \
            --apiKey "$ASC_KEY_ID" \
            --apiIssuer "$ASC_ISSUER_ID" 2>&1 \
        | redact \
        | tee "$ROOT/dist/ios/upload-only.log" \
        | helper upload_status
    )" || {
        echo "upload failed" >&2
        echo "details: dist/ios/upload-only.log" >&2
        exit 1
    }
    case "$STATUS" in
        succeeded*)
            echo "uploaded"
            if [ -n "${STATUS#succeeded }" ] && [ "$STATUS" != "succeeded" ]; then
                echo "delivery ${STATUS#succeeded }"
            fi
            ;;
        duplicate)
            echo "this build number has already been uploaded. Bump CURRENT_PROJECT_VERSION and run again (or pass --bump)." >&2
            exit 1
            ;;
        *)
            echo "upload failed" >&2
            exit 1
            ;;
    esac
    exit 0
fi

if [ "$BUMP" -eq 1 ]; then
    read_project_versions
    bump_build
else
    read_project_versions
fi

echo "tokenstat $VERSION ($BUILD)"

if [ "$SKIP_FFI" -eq 1 ]; then
    if [ ! -d "$ROOT/apps/mac/Vendor/TokenstatFFI.xcframework/ios-arm64" ]; then
        echo "the xcframework has no iOS device slice. omit --skip-ffi." >&2
        exit 1
    fi
    echo "reusing ffi"
else
    if ! command -v rustup >/dev/null || ! command -v cargo >/dev/null; then
        echo "rustup and cargo are required to build the ffi." >&2
        exit 1
    fi
    FFI_PLATFORMS="${TOKENSTAT_FFI_PLATFORMS:-macos ios sim}"
    echo "building ffi"
    # Deliberately unquoted: this is a list of platform words.
    # shellcheck disable=SC2086
    if ! run_redacted "dist/ios/ffi-$VERSION-$BUILD.log" \
        "$ROOT/scripts/build-ffi-xcframework.sh" $FFI_PLATFORMS; then
        fail_from_log "ffi build failed" "dist/ios/ffi-$VERSION-$BUILD.log"
    fi
fi

if ! command -v xcodegen >/dev/null; then
    echo "xcodegen is required: brew install xcodegen" >&2
    exit 1
fi
echo "generating xcode project"
(cd "$ROOT/apps/mac" && xcodegen >/dev/null)

resolve_team
EXPORT_PLIST="$TEMP_HOME/ExportOptions.plist"
write_export_options "$EXPORT_PLIST"

ARCHIVE_REL="dist/ios/Tokenstat-$VERSION-$BUILD.xcarchive"
EXPORT_REL="dist/ios/export-$VERSION-$BUILD"
IPA_REL="$EXPORT_REL/Tokenstat.ipa"
ARCHIVE_LOG="dist/ios/archive-$VERSION-$BUILD.log"
EXPORT_LOG="dist/ios/export-$VERSION-$BUILD.log"
UPLOAD_LOG="dist/ios/upload-$VERSION-$BUILD.log"

rm -rf "$ROOT/$ARCHIVE_REL" "$ROOT/$EXPORT_REL"
mkdir -p "$ROOT/dist/ios"

echo "archiving"
if ! run_redacted "$ARCHIVE_LOG" xcodebuild archive \
    -project "$ROOT/apps/mac/Tokenstat.xcodeproj" \
    -scheme Tokenstat \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ROOT/$ARCHIVE_REL" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$AUTH_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_IDENTITY="Apple Development"
then
    fail_from_log "archive failed" "$ARCHIVE_LOG"
fi
if ! grep -q 'ARCHIVE SUCCEEDED' "$ROOT/$ARCHIVE_LOG"; then
    fail_from_log "archive failed" "$ARCHIVE_LOG"
fi

echo "exporting"
if ! run_redacted "$EXPORT_LOG" xcodebuild -exportArchive \
    -archivePath "$ROOT/$ARCHIVE_REL" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$ROOT/$EXPORT_REL" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$AUTH_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
then
    fail_from_log "export failed" "$EXPORT_LOG"
fi
if ! grep -q 'EXPORT SUCCEEDED' "$ROOT/$EXPORT_LOG"; then
    fail_from_log "export failed" "$EXPORT_LOG"
fi
if [ ! -f "$ROOT/$IPA_REL" ]; then
    echo "export did not produce an IPA." >&2
    exit 1
fi

echo "checking IPA"
helper check_ipa "$ROOT/$IPA_REL" "$VERSION" "$BUILD"

if [ "$NO_UPLOAD" -eq 1 ]; then
    echo "not uploaded"
    echo "ipa $IPA_REL"
    exit 0
fi

echo "uploading"
mkdir -p "$ROOT/dist/ios"
STATUS="$(
    HOME="$TEMP_HOME" xcrun altool \
        --upload-app \
        --type ios \
        --file "$ROOT/$IPA_REL" \
        --apiKey "$ASC_KEY_ID" \
        --apiIssuer "$ASC_ISSUER_ID" 2>&1 \
    | redact \
    | tee "$ROOT/$UPLOAD_LOG" \
    | helper upload_status
)" || {
    echo "upload failed" >&2
    echo "details: $UPLOAD_LOG" >&2
    exit 1
}

case "$STATUS" in
    succeeded*)
        echo "uploaded $VERSION ($BUILD)"
        if [ "$STATUS" != "succeeded" ]; then
            echo "delivery ${STATUS#succeeded }"
        fi
        echo "build $BUILD is spent. next free number is $((BUILD + 1))."
        echo "TestFlight only: nothing was submitted for App Review."
        ;;
    duplicate)
        echo "this build number has already been uploaded. Bump CURRENT_PROJECT_VERSION and run again (or pass --bump)." >&2
        exit 1
        ;;
    *)
        echo "upload failed" >&2
        echo "details: $UPLOAD_LOG" >&2
        exit 1
        ;;
esac
