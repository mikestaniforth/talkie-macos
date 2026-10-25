#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/talkie-core-tests.XXXXXX")"
trap 'rm -rf "$task_build_dir"' EXIT

swiftc -swift-version 5 \
  -I "$task_root/Sources/CSQLite" \
  "$task_root/Sources/Talkie/TalkieEnvironment.swift" \
  "$task_root/Sources/Talkie/ProjectKit.swift" \
  "$task_root/Sources/Talkie/HistoryStore.swift" \
  "$task_root/Tests/CoreHarness.swift" \
  -o "$task_build_dir/talkie-core-tests"

"$task_build_dir/talkie-core-tests"
