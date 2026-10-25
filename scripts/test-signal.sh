#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/talkie-signal-tests.XXXXXX")"
trap 'rm -rf "$task_build_dir"' EXIT

swiftc -swift-version 5 \
  "$task_root/Sources/Talkie/AudioSignalCheck.swift" \
  "$task_root/Tests/SignalHarness.swift" \
  -o "$task_build_dir/talkie-signal-tests"

"$task_build_dir/talkie-signal-tests" "$@"
