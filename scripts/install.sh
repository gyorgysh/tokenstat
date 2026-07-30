#!/usr/bin/env bash
#
# tokenstat installer for macOS and Linux.
#
#   curl -fsSL https://tokenstat.ai/install.sh | sh
#
# Downloads the matching GitHub Release binary into ~/.local/bin (user-writable
# so `tokenstat update` works), verifies SHA256SUMS, and runs `tokenstat setup`
# (scan, hourly schedule, and a prompt to link an account when run on a TTY).
# Never ad-hoc codesigns: macOS release builds are Developer ID signed and
# notarized when CI secrets are set.
#
# Env / flags:
#   TOKENSTAT_VERSION=0.1.0   pin a release (without leading v)
#   TOKENSTAT_BIN_DIR=...     install directory (default: ~/.local/bin)
#   TOKENSTAT_NO_SCHEDULE=1   pass --no-schedule to setup
#   TOKENSTAT_YES=1           non-interactive (accept defaults)
#   GITHUB_TOKEN=...          optional, raises API rate limits
#   --no-schedule             same as TOKENSTAT_NO_SCHEDULE=1
#   --bin-dir DIR             same as TOKENSTAT_BIN_DIR
#   --version VER             same as TOKENSTAT_VERSION

set -euo pipefail

REPO="gyorgysh/tokenstat"
BIN_DIR="${TOKENSTAT_BIN_DIR:-$HOME/.local/bin}"
VERSION="${TOKENSTAT_VERSION:-}"
NO_SCHEDULE="${TOKENSTAT_NO_SCHEDULE:-0}"
YES="${TOKENSTAT_YES:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-schedule) NO_SCHEDULE=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --bin-dir)
      [ $# -ge 2 ] || { echo "✖ --bin-dir needs a path" >&2; exit 1; }
      BIN_DIR="$2"
      shift 2
      ;;
    --bin-dir=*) BIN_DIR="${1#--bin-dir=}"; shift ;;
    --version)
      [ $# -ge 2 ] || { echo "✖ --version needs a value" >&2; exit 1; }
      VERSION="$2"
      shift 2
      ;;
    --version=*) VERSION="${1#--version=}"; shift ;;
    --help|-h)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "✖ unknown flag: $1" >&2
      exit 1
      ;;
  esac
done

if [ -t 1 ]; then
  DIM=$'\033[2m'; R=$'\033[0m'
  CY=$'\033[36m'; GR=$'\033[32m'; YE=$'\033[33m'; RD=$'\033[31m'
else
  DIM=""; R=""; CY=""; GR=""; YE=""; RD=""
fi
say() { printf '%s\n' "${CY}•${R} $*"; }
ok() { printf '%s\n' "${GR}✓${R} $*"; }
warn() { printf '%s\n' "${YE}!${R} $*"; }
err() { printf '%s\n' "${RD}✖${R} $*" >&2; }
die() { err "$*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "need '$1' on PATH"
}

detect_target() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin)
      case "$arch" in
        arm64|aarch64) echo "aarch64-apple-darwin" ;;
        x86_64) echo "x86_64-apple-darwin" ;;
        *) die "unsupported macOS arch: $arch" ;;
      esac
      ;;
    Linux)
      case "$arch" in
        x86_64|amd64) echo "x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
        *) die "unsupported Linux arch: $arch" ;;
      esac
      ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      die "Windows: use PowerShell — irm https://tokenstat.ai/install.ps1 | iex"
      ;;
    *)
      die "unsupported OS: $os (macOS and Linux only for this script)"
      ;;
  esac
}

api_get() {
  local url="$1"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: tokenstat-install" \
      "$url"
  else
    curl -fsSL -H "Accept: application/vnd.github+json" \
      -H "User-Agent: tokenstat-install" \
      "$url"
  fi
}

resolve_version() {
  if [ -n "$VERSION" ]; then
    echo "${VERSION#v}"
    return
  fi
  local json tag
  json="$(api_get "https://api.github.com/repos/${REPO}/releases/latest")"
  tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [ -n "$tag" ] || die "could not read latest release tag from GitHub"
  echo "${tag#v}"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

expected_sha() {
  local sums_file="$1" asset="$2"
  awk -v want="$asset" '
    {
      hash=$1
      name=$2
      sub(/^\*/, "", name)
      if (name == want || name ~ "/" want "$") { print tolower(hash); exit }
    }
  ' "$sums_file"
}

ensure_path() {
  local dir="$1"
  case ":$PATH:" in
    *":$dir:"*) return 0 ;;
  esac
  warn "$dir is not on PATH yet"
  local line="export PATH=\"${dir}:\$PATH\""
  local profile=""
  if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
    profile="$HOME/.zprofile"
  elif [ -n "${BASH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "bash" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
      profile="$HOME/.bash_profile"
    else
      profile="$HOME/.bashrc"
    fi
  else
    profile="$HOME/.profile"
  fi
  if [ -f "$profile" ] && grep -F "$dir" "$profile" >/dev/null 2>&1; then
    say "PATH entry already in $profile (open a new shell)"
    return 0
  fi
  if [ "$YES" = "1" ] || [ ! -e /dev/tty ]; then
    printf '\n# tokenstat\n%s\n' "$line" >>"$profile"
    ok "appended PATH to $profile (open a new shell)"
  else
    printf 'Add %s to PATH in %s? [Y/n] ' "$dir" "$profile" >/dev/tty
    local ans=""
    read -r ans </dev/tty || ans="Y"
    case "${ans:-Y}" in
      [Nn]*) warn "skip PATH edit; add manually: $line" ;;
      *)
        printf '\n# tokenstat\n%s\n' "$line" >>"$profile"
        ok "appended PATH to $profile (open a new shell)"
        ;;
    esac
  fi
}

main() {
  need_cmd curl
  need_cmd tar
  need_cmd uname
  command -v sha256sum >/dev/null 2>&1 || need_cmd shasum

  local target version asset archive_url sums_url tmp dest
  target="$(detect_target)"
  version="$(resolve_version)"
  asset="tokenstat-${version}-${target}.tar.gz"
  archive_url="https://github.com/${REPO}/releases/download/v${version}/${asset}"
  sums_url="https://github.com/${REPO}/releases/download/v${version}/SHA256SUMS"

  say "installing tokenstat v${version} (${target})"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tokenstat-install.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT

  say "downloading ${asset}"
  curl -fsSL -o "$tmp/$asset" "$archive_url" \
    || die "download failed: $archive_url"
  curl -fsSL -o "$tmp/SHA256SUMS" "$sums_url" \
    || die "download failed: $sums_url"

  local want got
  want="$(expected_sha "$tmp/SHA256SUMS" "$asset")"
  [ -n "$want" ] || die "SHA256SUMS has no entry for $asset"
  got="$(sha256_file "$tmp/$asset")"
  [ "$got" = "$want" ] || die "checksum mismatch: expected $want, got $got"
  ok "checksum ok"

  tar -xzf "$tmp/$asset" -C "$tmp"
  local extracted
  extracted="$(find "$tmp" -type f -name tokenstat | head -n1)"
  [ -n "$extracted" ] || die "archive did not contain tokenstat"
  chmod +x "$extracted"

  mkdir -p "$BIN_DIR"
  dest="$BIN_DIR/tokenstat"
  cp -f "$extracted" "$dest.new"
  mv -f "$dest.new" "$dest"
  if [ "$(uname -s)" = "Darwin" ]; then
    # Clear quarantine only. Do not ad-hoc re-sign (strips Developer ID).
    xattr -cr "$dest" 2>/dev/null || true
  fi
  ok "installed $dest"

  ensure_path "$BIN_DIR"
  export PATH="${BIN_DIR}:$PATH"

  say "running setup (scan, schedule, optional account link)"
  setup_args=()
  if [ "$NO_SCHEDULE" = "1" ]; then
    setup_args+=(--no-schedule)
  fi
  "$dest" setup "${setup_args[@]}" || warn "setup reported an error (you can re-run: tokenstat setup)"

  echo
  ok "tokenstat v${version} ready"
  echo "  ${DIM}try:${R}  tokenstat"
  echo "  ${DIM}link:${R} tokenstat login"
  echo "  ${DIM}check:${R} tokenstat doctor"
  echo "  ${DIM}update:${R} tokenstat update"
  echo
}

main
