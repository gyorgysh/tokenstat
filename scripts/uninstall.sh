#!/usr/bin/env bash
#
# tokenstat uninstaller for macOS and Linux.
#
#   curl -fsSL https://tokenstat.ai/uninstall.sh | bash
#
# Removes the hourly scan schedule, then the binary. Leaves the local archive
# alone unless you pass --purge (your scanned history, including usage coding
# tools have already deleted). Does not touch a hosted tokenstat.ai profile.
#
# Env / flags:
#   TOKENSTAT_BIN_DIR=...   binary directory (default: ~/.local/bin)
#   TOKENSTAT_PURGE=1       also delete the local data directory
#   TOKENSTAT_YES=1         non-interactive (needed with --purge when no TTY)
#   --purge                 same as TOKENSTAT_PURGE=1
#   --bin-dir DIR           same as TOKENSTAT_BIN_DIR
#   --yes / -y              same as TOKENSTAT_YES=1

# Piped into dash (/bin/sh on many Linux distros): re-exec under bash.
if [ -z "${BASH_VERSION:-}" ]; then
  if ! command -v bash >/dev/null 2>&1; then
    echo "✖ tokenstat uninstaller requires bash" >&2
    exit 1
  fi
  case "$(basename "$0")" in
    sh|dash|ash) exec bash -s -- "$@" ;;
    *) exec bash "$0" "$@" ;;
  esac
fi

set -euo pipefail

# Every scheduler entry tokenstat can install. All of them are removed whether or
# not this machine ever had them: a leftover unit pointing at a deleted binary is
# the worst thing an uninstaller can leave behind.
LABELS="ai.tokenstat.scan ai.tokenstat.sync ai.tokenstat.update"
BIN_DIR="${TOKENSTAT_BIN_DIR:-$HOME/.local/bin}"
PURGE="${TOKENSTAT_PURGE:-0}"
YES="${TOKENSTAT_YES:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --bin-dir)
      [ $# -ge 2 ] || { echo "✖ --bin-dir needs a path" >&2; exit 1; }
      BIN_DIR="$2"
      shift 2
      ;;
    --bin-dir=*) BIN_DIR="${1#--bin-dir=}"; shift ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
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

if [ -e /dev/tty ] && [ -r /dev/tty ]; then TTY=/dev/tty; else TTY=""; fi

# confirm "Question" -> 0 for yes. Default No. TOKENSTAT_YES=1 accepts.
confirm_no() {
  local prompt="$1" ans=""
  if [ "$YES" = "1" ]; then
    return 0
  fi
  [ -z "$TTY" ] && return 1
  printf '%s [y/N] ' "$prompt" >"$TTY"
  read -r ans <"$TTY" || ans=""
  case "${ans}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

data_dir() {
  case "$(uname -s)" in
    Darwin) printf '%s\n' "$HOME/Library/Application Support/ai.tokenstat.tokenstat" ;;
    Linux) printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/tokenstat" ;;
    *) die "unsupported OS: $(uname -s)" ;;
  esac
}

cache_dir() {
  case "$(uname -s)" in
    Darwin) printf '%s\n' "$HOME/Library/Caches/ai.tokenstat.tokenstat" ;;
    Linux) printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/tokenstat" ;;
    *) printf '%s\n' "" ;;
  esac
}

remove_one_schedule() {
  local label="$1"
  case "$(uname -s)" in
    Darwin)
      local plist="$HOME/Library/LaunchAgents/${label}.plist"
      local log="$HOME/Library/Logs/${label}.log"
      local domain="gui/$(id -u)"
      if [ -f "$plist" ] || launchctl print "${domain}/${label}" >/dev/null 2>&1; then
        say "removing LaunchAgent ${label}"
        launchctl bootout "${domain}" "${label}" 2>/dev/null || true
        launchctl unload -w "$plist" 2>/dev/null || true
        rm -f "$plist"
        rm -f "$log"
        ok "${label} removed"
      else
        say "no LaunchAgent ${label} found"
      fi
      ;;
    Linux)
      if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemctl not found; skip schedule cleanup"
        return 0
      fi
      local unit_dir="$HOME/.config/systemd/user"
      local service="${unit_dir}/${label}.service"
      local timer="${unit_dir}/${label}.timer"
      if [ -f "$timer" ] || [ -f "$service" ] \
        || systemctl --user is-enabled "${label}.timer" >/dev/null 2>&1; then
        say "disabling systemd user timer ${label}"
        systemctl --user disable --now "${label}.timer" 2>/dev/null || true
        systemctl --user disable --now "${label}.service" 2>/dev/null || true
        rm -f "$service" "$timer"
        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user reset-failed "${label}.timer" 2>/dev/null || true
        systemctl --user reset-failed "${label}.service" 2>/dev/null || true
        ok "${label} removed"
      else
        say "no systemd timer ${label} found"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      die "Windows: use PowerShell. Run irm https://tokenstat.ai/uninstall.ps1 | iex"
      ;;
  esac
}

remove_schedule() {
  for label in $LABELS; do
    remove_one_schedule "$label"
  done
}

remove_binary() {
  local dest="$BIN_DIR/tokenstat"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    say "removing $dest"
    rm -f "$dest"
    ok "binary removed"
  else
    say "no binary at $dest"
  fi
}

remove_data() {
  local dir cache
  dir="$(data_dir)"
  cache="$(cache_dir)"
  if [ ! -d "$dir" ] && { [ -z "$cache" ] || [ ! -d "$cache" ]; }; then
    say "no local data directory found"
    return 0
  fi
  warn "this deletes your local archive (usage your tools may already have purged)"
  say "data: $dir"
  [ -n "$cache" ] && [ -d "$cache" ] && say "cache: $cache"
  if ! confirm_no "Delete local archive and cache?"; then
    if [ "$PURGE" = "1" ] && [ -z "$TTY" ] && [ "$YES" != "1" ]; then
      warn "purge skipped (piped uninstall needs --yes with --purge)"
    else
      say "left data in place"
    fi
    return 0
  fi
  if [ -d "$dir" ]; then
    rm -rf "$dir"
    ok "removed $dir"
  fi
  if [ -n "$cache" ] && [ -d "$cache" ]; then
    rm -rf "$cache"
    ok "removed $cache"
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    # Legacy sync tokens may still sit in the login keychain.
    if security delete-generic-password -s "ai.tokenstat.sync" >/dev/null 2>&1; then
      ok "removed keychain entries for ai.tokenstat.sync"
    else
      say "no ai.tokenstat.sync keychain entry (or left for Keychain Access)"
    fi
  fi
}

main() {
  echo
  say "uninstalling tokenstat"
  echo

  remove_schedule
  remove_binary

  if [ "$PURGE" = "1" ]; then
    remove_data
  else
    local dir
    dir="$(data_dir)"
    if [ -d "$dir" ]; then
      say "left archive at $dir"
      echo "  ${DIM}re-run with --purge to delete it${R}"
    fi
  fi

  echo
  ok "local install removed"
  echo "  ${DIM}hosted profile untouched. Export or delete from /settings/data if needed${R}"
  echo "  ${DIM}PATH lines in shell profiles are harmless; remove by hand if you want${R}"
  echo
}

main
