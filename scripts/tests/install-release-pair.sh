#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Exercise the actual installer function without downloads or service changes.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/tokenstat-pair-test.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
sed -n '/^install_release_pair() (/,/^)/p' "$root/scripts/install.sh" > "$work/function.sh"
[ -s "$work/function.sh" ]
. "$work/function.sh"
printf 'new cli\n' > "$work/new-cli"
printf 'new host\n' > "$work/new-host"
mode=success
cp() {
  if [ "$mode" = copy ] && [ "$2" = "$work/new-host" ]; then return 41; fi
  /bin/cp "$@"
}
mv() {
  case "$mode:$(basename "$2")" in
    first:tokenstat-hostd|second:tokenstat|rollback:tokenstat|rollback:previous-hostd) return 42 ;;
  esac
  /bin/mv "$@"
}
for mode in success copy first second rollback; do
  directory="$work/$mode"
  mkdir "$directory"
  printf 'old cli\n' > "$directory/tokenstat"
  printf 'old host\n' > "$directory/tokenstat-hostd"
  if install_release_pair "$work/new-cli" "$work/new-host" "$directory" > "$work/output" 2>&1; then
    [ "$mode" = success ]
    [ "$(cat "$directory/tokenstat")" = 'new cli' ]
    [ "$(cat "$directory/tokenstat-hostd")" = 'new host' ]
  else
    [ "$mode" != success ]
    [ "$(cat "$directory/tokenstat")" = 'old cli' ]
    if [ "$mode" = rollback ]; then
      previous="$(find "$directory" -name previous-hostd -type f)"
      [ -n "$previous" ] && [ "$(cat "$previous")" = 'old host' ]
      grep -F "$previous" "$work/output" >/dev/null
    else
      [ "$(cat "$directory/tokenstat-hostd")" = 'old host' ]
      [ "$(find "$directory" -name '.tokenstat-install.*' | wc -l | tr -d ' ')" = 0 ]
    fi
  fi
done
# A failed first installation leaves no newly installed daemon behind.
mode=second
directory="$work/first-install"
mkdir "$directory"
if install_release_pair "$work/new-cli" "$work/new-host" "$directory" >/dev/null 2>&1; then exit 1; fi
[ ! -e "$directory/tokenstat" ] && [ ! -e "$directory/tokenstat-hostd" ]
# Restore the link itself, without replacing the executable it points to.
directory="$work/symlink"
mkdir "$directory"
printf 'linked host\n' > "$work/original-host"
ln -s "$work/original-host" "$directory/tokenstat-hostd"
if install_release_pair "$work/new-cli" "$work/new-host" "$directory" >/dev/null 2>&1; then exit 1; fi
[ -L "$directory/tokenstat-hostd" ]
[ "$(readlink "$directory/tokenstat-hostd")" = "$work/original-host" ]
[ "$(cat "$work/original-host")" = 'linked host' ]
printf 'Installer pair: copy/rename failures preserve previous files; failed rollback retains recovery copy; new installs and symlinks passed\n'
