#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/talkie-capture-tests.XXXXXX")"
trap 'rm -rf "$task_build_dir"' EXIT

swiftc -swift-version 5 \
  "$task_root/Sources/Talkie/RepeatedAudioCheck.swift" \
  "$task_root/Tests/CaptureHarness.swift" \
  -o "$task_build_dir/talkie-capture-tests"

"$task_build_dir/talkie-capture-tests" "$@"

cat "$task_root/Sources/Talkie/AudioCapture.swift" "$task_root/Tests/WriterHarness.swift" \
  > "$task_build_dir/WriterHarnessCombined.swift"
swiftc -parse-as-library -swift-version 5 \
  "$task_root/Sources/Talkie/RepeatedAudioCheck.swift" \
  "$task_build_dir/WriterHarnessCombined.swift" \
  -o "$task_build_dir/talkie-writer-tests"
"$task_build_dir/talkie-writer-tests"
