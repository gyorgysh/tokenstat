#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# CI only: start and stop a dedicated disposable emulator, never a user's device.
set -euo pipefail
: "${ANDROID_HOME:?ANDROID_HOME is required}"
chart_port=5584
chart_serial="emulator-$chart_port"
chart_avd="tokenstat-chart-ci"
chart_sdk="$ANDROID_HOME/cmdline-tools/latest/bin"
if "$ANDROID_HOME/platform-tools/adb" devices | rg -q "^${chart_serial}[[:space:]]"; then
  echo "Refusing to reuse an existing chart test device" >&2
  exit 1
fi
"$chart_sdk/sdkmanager" 'emulator' 'system-images;android-36;google_apis;x86_64'
printf 'no\n' | "$chart_sdk/avdmanager" create avd -n "$chart_avd" -k 'system-images;android-36;google_apis;x86_64' --device pixel_7
mkdir -p target/chart-android-ci
"$ANDROID_HOME/emulator/emulator" -avd "$chart_avd" -port "$chart_port" -no-window -no-audio -no-snapshot -gpu swiftshader > target/chart-android-ci/emulator.log 2>&1 &
chart_pid=$!
cleanup() { kill "$chart_pid" 2>/dev/null || true; wait "$chart_pid" 2>/dev/null || true; }
trap cleanup EXIT
for chart_attempt in $(seq 1 120); do
  kill -0 "$chart_pid" || { cat target/chart-android-ci/emulator.log; exit 1; }
  if [ "$("$ANDROID_HOME/platform-tools/adb" -s "$chart_serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
    ANDROID_SERIAL="$chart_serial" gradle -p apps/android connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=ai.tokenstat.tokenstat.ui.workspace.ChatChartTest
    exit 0
  fi
  sleep 2
done
echo 'Chart emulator did not finish booting' >&2
cat target/chart-android-ci/emulator.log
exit 1
