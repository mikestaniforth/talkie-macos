#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/talkie-hotkey-tests.XXXXXX")"
trap 'rm -rf "$task_build_dir"' EXIT

swiftc -swift-version 5 \
  "$task_root/Sources/Talkie/GlobalHotkey.swift" \
  "$task_root/Tests/HotkeyHarness.swift" \
  -o "$task_build_dir/talkie-hotkey-tests"

"$task_build_dir/talkie-hotkey-tests"
