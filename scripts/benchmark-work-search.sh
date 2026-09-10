#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Synthetic release-mode index benchmark. Arguments: bytes/message, repetitions.
# 1024 measures a 10 MB corpus; 10000 measures near the 100 MB cache budget.
# Optional third argument "varied" uses deterministic high-variety ASCII bodies.
# JSON timing results go to stdout, /usr/bin/time peak memory goes to stderr.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$root/target"
swiftc -O -parse-as-library -swift-version 5 \
  "$root/apps/mac/Sources/Features/Work/WorkReference.swift" \
  "$root/apps/mac/Sources/Features/Work/WorkSearchText.swift" \
  "$root/apps/mac/Sources/Features/Work/WorkSearchIndex.swift" \
  "$root/scripts/benchmarks/WorkSearchBenchmark.swift" \
  -o "$root/target/WorkSearchBenchmark"
/usr/bin/time -l "$root/target/WorkSearchBenchmark" "${1:-1024}" "${2:-20}" "${3:-repeated}"
