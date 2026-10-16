#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Run the native decoder benchmark on a connected QA emulator/device. The
# optional directory is copied only into the test app's private files folder.
# Originals and fixture contents never enter the repository or a network API.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="${1:?Pass a local directory with one to four image fixtures}"
serial="${2:?Pass the explicit adb device serial}"
adb="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}/platform-tools/adb"
generated="$root/apps/android/app/src/androidTest/java/ai/tokenstat/tokenstat/ui/workspace/AndroidChatImages.kt"
test_folder="chat-perf-$(date +%s)-$$"
cleanup() {
  rm -f "$generated" "$run_log"
  "$adb" -s "$serial" shell run-as ai.tokenstat.tokenstat rm -rf "files/$test_folder" >/dev/null 2>&1 || true
}
test ! -e "$generated"
run_log="$(mktemp)"
trap cleanup EXIT
cp "$root/scripts/benchmarks/AndroidChatImages.kt" "$generated"
"$root/apps/android/gradlew" -p "$root/apps/android" :app:assembleDebug :app:assembleDebugAndroidTest --max-workers=3
"$adb" -s "$serial" install -r "$root/apps/android/app/build/outputs/apk/debug/app-debug.apk"
"$adb" -s "$serial" install -r "$root/apps/android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
"$adb" -s "$serial" shell run-as ai.tokenstat.tokenstat mkdir -p "files/$test_folder"
count=0
while IFS= read -r -d '' file; do
  count=$((count + 1))
  test "$count" -le 4 || break
  "$adb" -s "$serial" shell run-as ai.tokenstat.tokenstat sh -c "'cat > files/$test_folder/image-$count'" < "$file"
done < <(find "$fixture" -maxdepth 1 -type f -print0)
test "$count" -gt 0
"$adb" -s "$serial" shell am instrument -w -r -e class ai.tokenstat.tokenstat.ui.workspace.AndroidChatImages \
  -e chatImageBenchmark "$test_folder" ai.tokenstat.tokenstat.test/androidx.test.runner.AndroidJUnitRunner | tee "$run_log"
# `am instrument` can exit zero for a failed JUnit test. Require its positive
# one-test result before reading this run's report, never an earlier report.
if ! grep -Eq '^OK \(1 test\)[[:space:]]*$' "$run_log"; then
  echo "The native image benchmark did not pass its instrumentation test." >&2
  exit 1
fi
"$adb" -s "$serial" shell run-as ai.tokenstat.tokenstat cat "files/$test_folder/benchmark.json"
