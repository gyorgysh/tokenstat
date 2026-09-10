#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Actual removal/main functions, private roots and mocked service commands.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/tokenstat-uninstall-test.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
sed -n '/^remove_host() {/,/^}/p' "$root/scripts/uninstall.sh" | sed 's/^remove_host()/remove_host_actual()/' > "$work/functions"
sed -n '/^main() {/,/^}/p' "$root/scripts/uninstall.sh" >> "$work/functions"
. "$work/functions"
remove_host() { remove_host_actual "$test_home" "$test_system"; }
uname() { printf '%s\n' "$test_os"; }
id() { printf '%s\n' "$test_uid"; }
launchctl() {
  case "$1" in
    print) [ "$test_loaded" = 1 ] && [ "$2" = "gui/$test_uid/ai.tokenstat.hostd" ] ;;
    bootout) [ "$test_fail" = 0 ] ;;
    *) return 99 ;;
  esac
}
systemctl() { [ "$test_fail" = 0 ]; }
say() { printf '%s\n' "$*"; }
ok() { say "$@"; }
warn() { say "$@"; }
remove_schedule() { :; }
remove_binary() { rm -f "$test_home/binary"; }
data_dir() { printf '%s\n' "$test_home/absent-data"; }
PURGE=0 DIM='' R=''
for scenario in mac-success mac-stopped mac-failed linux-success linux-failed linux-system-denied linux-system-root; do
  test_home="$work/$scenario"
  test_system="$test_home/system"
  mkdir -p "$test_home/Library/LaunchAgents" "$test_home/Library/Logs/tokenstat" "$test_home/.config/systemd/user" "$test_system"
  printf 'keep binary\n' > "$test_home/binary"
  test_uid=501 test_loaded=1 test_fail=0
  case "$scenario" in
    mac-*)
      test_os=Darwin
      unit="$test_home/Library/LaunchAgents/ai.tokenstat.hostd.plist"
      printf 'log\n' > "$test_home/Library/Logs/tokenstat/hostd.out.log"
      ;;
    linux-*) test_os=Linux; unit="$test_home/.config/systemd/user/tokenstat-host.service" ;;
  esac
  case "$scenario" in
    mac-stopped) test_loaded=0 ;;
    mac-failed|linux-failed) test_fail=1 ;;
    linux-system-denied) unit="$test_system/tokenstat-host.service" ;;
    linux-system-root) test_uid=0; unit="$test_system/tokenstat-host.service" ;;
  esac
  printf 'service definition\n' > "$unit"
  if main > "$work/output" 2>&1; then
    case "$scenario" in mac-failed|linux-failed|linux-system-denied) echo "unexpected success: $scenario"; exit 1 ;; esac
    [ ! -e "$unit" ] && [ ! -e "$test_home/binary" ]
    grep -F 'host service removed' "$work/output" >/dev/null
    if [ "$test_os" = Darwin ]; then [ ! -e "$test_home/Library/Logs/tokenstat/hostd.out.log" ]; fi
  else
    case "$scenario" in mac-failed|linux-failed|linux-system-denied) ;; *) cat "$work/output"; exit 1 ;; esac
    [ -f "$unit" ] && [ -f "$test_home/binary" ]
    if grep -F 'local install removed' "$work/output" >/dev/null; then exit 1; fi
  fi
done
printf 'Uninstaller: stopped/successful services clean up; stop failures and insufficient service authority preserve binaries/configuration\n'
