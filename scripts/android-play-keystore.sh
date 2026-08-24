#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#
# Play upload keystore. Lives on this machine, never in git.
#
# Google holds the app signing key (Play App Signing). This keystore only
# signs the App Bundle we upload. Same split as the Apple Developer ID P12:
# the identity is a local secret, CI gets a copy through the `release`
# environment, the repository never sees it.
#
# Usage:
#   scripts/android-play-keystore.sh init
#   scripts/android-play-keystore.sh fingerprints
#   scripts/android-play-keystore.sh status
#   scripts/android-play-keystore.sh push-github
#
# `init` is idempotent. It refuses to overwrite an existing keystore.

set -euo pipefail

DIR="${TOKENSTAT_ANDROID_KEYSTORE_DIR:-$HOME/.tokenstat/android}"
KEYSTORE="$DIR/play.jks"
ENV_FILE="$DIR/play.env"
CERT_PEM="$DIR/upload.pem"
FINGERPRINTS="$DIR/fingerprints.txt"
ALIAS="upload"
DNAME="CN=ai.tokenstat.tokenstat, O=pueev OU, C=EE"

usage() {
    cat <<'EOF'
usage: scripts/android-play-keystore.sh <command>

  init           create the upload keystore if it does not exist
  fingerprints   print SHA-1 / SHA-256 of the upload cert (and debug, if present)
  status         whether the keystore, env file, and GitHub secrets exist
  push-github    copy the keystore into the GitHub `release` environment

The keystore path is ~/.tokenstat/android/play.jks. Source play.env before a
local release build:

  set -a && source ~/.tokenstat/android/play.env && set +a
  scripts/build-android-release.sh
EOF
}

need_keystore() {
    if [ ! -f "$KEYSTORE" ]; then
        echo "error: no keystore at $KEYSTORE" >&2
        echo "hint: scripts/android-play-keystore.sh init" >&2
        exit 1
    fi
}

load_env() {
    need_keystore
    if [ ! -f "$ENV_FILE" ]; then
        echo "error: no env file at $ENV_FILE" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    set -a && source "$ENV_FILE" && set +a
}

write_fingerprints() {
    load_env
    {
        echo "upload alias=$ALIAS"
        keytool -list -v \
            -keystore "$KEYSTORE" \
            -storepass "$TOKENSTAT_ANDROID_STORE_PASSWORD" \
            -alias "$ALIAS" \
            | awk '
                /^Owner:/ { print }
                /^Issuer:/ { print }
                /^Valid from:/ { print }
                /SHA1:/ { print }
                /SHA256:/ { print }
            '
    } >"$FINGERPRINTS"

    keytool -exportcert -rfc -noprompt \
        -keystore "$KEYSTORE" \
        -storepass "$TOKENSTAT_ANDROID_STORE_PASSWORD" \
        -alias "$ALIAS" \
        -file "$CERT_PEM" >/dev/null

    chmod 600 "$FINGERPRINTS" "$CERT_PEM"
}

cmd_init() {
    umask 077
    mkdir -p "$DIR"
    if [ -f "$KEYSTORE" ]; then
        echo "keystore already exists at $KEYSTORE"
        write_fingerprints
        cat "$FINGERPRINTS"
        return 0
    fi

    command -v keytool >/dev/null || {
        echo "error: keytool is required (JDK 17)" >&2
        exit 1
    }
    command -v openssl >/dev/null || {
        echo "error: openssl is required to generate the store password" >&2
        exit 1
    }

    local pass
    pass="$(openssl rand -hex 32)"

    keytool -genkeypair -noprompt \
        -keystore "$KEYSTORE" \
        -storetype PKCS12 \
        -alias "$ALIAS" \
        -keyalg RSA \
        -keysize 4096 \
        -validity 10000 \
        -storepass "$pass" \
        -keypass "$pass" \
        -dname "$DNAME"

    cat >"$ENV_FILE" <<EOF
# Play upload key. chmod 600. never commit.
export TOKENSTAT_ANDROID_KEYSTORE="$KEYSTORE"
export TOKENSTAT_ANDROID_STORE_PASSWORD='$pass'
export TOKENSTAT_ANDROID_KEY_ALIAS='$ALIAS'
export TOKENSTAT_ANDROID_KEY_PASSWORD='$pass'
EOF

    cat >"$DIR/README.txt" <<'EOF'
tokenstat Play upload key.

Google holds the app signing key (Play App Signing). This keystore only
signs the App Bundle we upload. Do not copy it into the git repository.
Do not email it. The GitHub `release` environment holds a copy as
ANDROID_KEYSTORE_BASE64.

Source play.env before a local release build. Print fingerprints with
scripts/android-play-keystore.sh fingerprints.
EOF

    chmod 600 "$KEYSTORE" "$ENV_FILE"
    write_fingerprints
    echo "created $KEYSTORE"
    cat "$FINGERPRINTS"
}

cmd_fingerprints() {
    write_fingerprints
    cat "$FINGERPRINTS"
    echo
    echo "PEM: $CERT_PEM"

    local debug="$HOME/.android/debug.keystore"
    if [ -f "$debug" ]; then
        echo
        echo "debug (sideload / Firebase debug apps, not Play)"
        keytool -list -v \
            -keystore "$debug" \
            -storepass android \
            -alias androiddebugkey \
            | awk '
                /^Owner:/ { print }
                /SHA1:/ { print }
                /SHA256:/ { print }
            '
    fi
}

cmd_status() {
    if [ -f "$KEYSTORE" ]; then
        echo "keystore: $KEYSTORE"
    else
        echo "keystore: missing"
    fi
    if [ -f "$ENV_FILE" ]; then
        echo "env:      $ENV_FILE"
    else
        echo "env:      missing"
    fi
    if [ -f "$CERT_PEM" ]; then
        echo "pem:      $CERT_PEM"
    else
        echo "pem:      missing"
    fi

    if command -v gh >/dev/null; then
        echo
        echo "GitHub release environment:"
        local listing
        listing="$(gh secret list --env release 2>/dev/null || true)"
        for name in ANDROID_KEYSTORE_BASE64 ANDROID_STORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD GOOGLE_PLAY_SERVICE_ACCOUNT_JSON; do
            if printf '%s\n' "$listing" | grep -q "^${name}"; then
                echo "  $name: set"
            else
                echo "  $name: missing"
            fi
        done
    fi
}

cmd_push_github() {
    load_env
    command -v gh >/dev/null || {
        echo "error: gh is required to set GitHub secrets" >&2
        exit 1
    }

    local b64
    b64="$(base64 <"$KEYSTORE" | tr -d '\n')"
    printf '%s' "$b64" | gh secret set ANDROID_KEYSTORE_BASE64 --env release
    printf '%s' "$TOKENSTAT_ANDROID_STORE_PASSWORD" | gh secret set ANDROID_STORE_PASSWORD --env release
    printf '%s' "$TOKENSTAT_ANDROID_KEY_ALIAS" | gh secret set ANDROID_KEY_ALIAS --env release
    printf '%s' "$TOKENSTAT_ANDROID_KEY_PASSWORD" | gh secret set ANDROID_KEY_PASSWORD --env release
    echo "wrote ANDROID_KEYSTORE_BASE64, ANDROID_STORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD to the release environment"
    echo "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON is not set here: that JSON comes from Play Console after the app exists."
}

cmd="${1:-}"
case "$cmd" in
    init) cmd_init ;;
    fingerprints) cmd_fingerprints ;;
    status) cmd_status ;;
    push-github) cmd_push_github ;;
    -h|--help|help|"") usage ;;
    *)
        echo "error: unknown command '$cmd'" >&2
        usage >&2
        exit 1
        ;;
esac
