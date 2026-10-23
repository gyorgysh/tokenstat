#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# CI only: start and stop a dedicated disposable emulator, never a user's device.
set -euo pipefail
: "${ANDROID_HOME:?ANDROID_HOME is required}"
chart_port=5584
chart_serial="emulator-$chart_port"
chart_avd="tokenstat-chart-ci"
chart_sdk="$ANDROID_HOME/cmdline-tools/latest/bin"
# Keep old and current SDK tools on the same disposable configuration directory.
chart_state="$PWD/target/chart-android-ci-state"
export ANDROID_SDK_HOME="$chart_state"
export ANDROID_USER_HOME="$chart_state/.android"
export ANDROID_EMULATOR_HOME="$ANDROID_USER_HOME"
export ANDROID_AVD_HOME="$ANDROID_USER_HOME/avd"
mkdir -p "$ANDROID_AVD_HOME" target/chart-android-ci
if "$ANDROID_HOME/platform-tools/adb" devices | rg -q "^${chart_serial}[[:space:]]"; then
  echo "Refusing to reuse an existing chart test device" >&2
  exit 1
fi
"$chart_sdk/sdkmanager" 'emulator' 'system-images;android-36;google_apis;x86_64'
if [ -e "$ANDROID_AVD_HOME/$chart_avd.ini" ]; then
  echo "Refusing to replace an existing chart test AVD" >&2
  exit 1
fi
printf 'no\n' | "$chart_sdk/avdmanager" create avd -n "$chart_avd" -k 'system-images;android-36;google_apis;x86_64' --device pixel_7 -p "$ANDROID_AVD_HOME/$chart_avd.avd"
chart_pid=""
cleanup() {
  if [ -n "$chart_pid" ]; then
    kill "$chart_pid" 2>/dev/null || true
    wait "$chart_pid" 2>/dev/null || true
  fi
  "$chart_sdk/avdmanager" delete avd -n "$chart_avd" > target/chart-android-ci/cleanup.log 2>&1 || true
}
trap cleanup EXIT
"$ANDROID_HOME/emulator/emulator" -list-avds | grep -Fx "$chart_avd"
"$ANDROID_HOME/emulator/emulator" -avd "$chart_avd" -port "$chart_port" -no-window -no-audio -no-snapshot -gpu swiftshader > target/chart-android-ci/emulator.log 2>&1 &
chart_pid=$!
for chart_attempt in $(seq 1 120); do
  kill -0 "$chart_pid" || { cat target/chart-android-ci/emulator.log; exit 1; }
  if [ "$("$ANDROID_HOME/platform-tools/adb" -s "$chart_serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
    for chart_suite in \
      ai.tokenstat.tokenstat.ui.workspace.ChatChartTest \
      ai.tokenstat.tokenstat.ui.team.TeamCommentTest \
      ai.tokenstat.tokenstat.ui.team.TeamBrowserTest \
      ai.tokenstat.tokenstat.ui.team.TeamDirectoryTest \
      ai.tokenstat.tokenstat.ui.team.TeamManagementTest \
      ai.tokenstat.tokenstat.ui.team.TeamLifecycleTest \
      ai.tokenstat.tokenstat.ui.team.TeamTranscriptTest; do
      ANDROID_SERIAL="$chart_serial" gradle -p apps/android connectedDebugAndroidTest "-Pandroid.testInstrumentationRunnerArguments.class=$chart_suite"
      chart_reports="target/chart-android-ci/$chart_suite"
      mkdir -p "$chart_reports"
      cp -R apps/android/app/build/outputs/androidTest-results "$chart_reports/results"
      cp -R apps/android/app/build/reports/androidTests "$chart_reports/reports"
      python3 scripts/tests/check-android-native-results.py "$chart_reports/results" "$chart_suite"
    done
    "$ANDROID_HOME/platform-tools/adb" -s "$chart_serial" pull /sdcard/Pictures/tokenstat-teams-qa target/chart-android-ci/screenshots
    exit 0
  fi
  sleep 2
done
echo 'Chart emulator did not finish booting' >&2
cat target/chart-android-ci/emulator.log
exit 1
