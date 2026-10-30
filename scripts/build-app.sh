#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_CONFIGURATION="${CONFIGURATION:-release}"
TASK_CACHE="$HOME/Library/Caches/talkie-preview-build"
TASK_STAGE="$TASK_CACHE/Source"
mkdir -p "$TASK_STAGE"
# Keep compiler intermediates and dependency checkouts out of iCloud Drive.
# This is a generated mirror; the workspace remains the source of truth.
rsync -a --delete "$TASK_ROOT/Sources/" "$TASK_STAGE/Sources/"
rsync -a --delete "$TASK_ROOT/Tests/" "$TASK_STAGE/Tests/"
cp -p Package.swift Package.resolved "$TASK_STAGE/"
cd "$TASK_STAGE"
TASK_BIN_DIR="$(swift build --package-path "$TASK_STAGE" --scratch-path "$TASK_CACHE/Build" -c "$TASK_CONFIGURATION" --show-bin-path)"
swift build --package-path "$TASK_STAGE" --scratch-path "$TASK_CACHE/Build" -c "$TASK_CONFIGURATION"
TASK_APP="$TASK_CACHE/Artifacts/Talkie Preview.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp "$TASK_BIN_DIR/Talkie" "$TASK_APP/Contents/MacOS/Talkie"
cp "$TASK_ROOT/Sources/Talkie/Resources/activate.wav" "$TASK_APP/Contents/Resources/activate.wav"
cp "$TASK_ROOT/THIRD_PARTY_NOTICES.md" "$TASK_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [ -f "$TASK_ROOT/LICENSE" ]; then cp "$TASK_ROOT/LICENSE" "$TASK_APP/Contents/Resources/LICENSE"; fi
swift "$TASK_ROOT/scripts/make-icon.swift" "$TASK_ROOT/dist/TalkiePreview.iconset" "$TASK_APP/Contents/Resources/Talkie.icns"
for TASK_RESOURCE in "$TASK_BIN_DIR"/*.bundle; do
    if [ -d "$TASK_RESOURCE" ]; then cp -R "$TASK_RESOURCE" "$TASK_APP/Contents/Resources/"; fi
done
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.talkie.preview</string>
<key>CFBundleName</key><string>Talkie Preview</string>
<key>CFBundleDisplayName</key><string>Talkie Preview</string>
<key>CFBundleExecutable</key><string>Talkie</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.5</string>
<key>CFBundleVersion</key><string>7</string>
<key>CFBundleIconFile</key><string>Talkie.icns</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><false/>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Talkie Preview records your voice only while you dictate or run a microphone test. Speech recognition runs locally on your Mac.</string>
<key>NSAccessibilityUsageDescription</key><string>Talkie Preview inserts your saved dictation into the text field you selected.</string>
</dict></plist>
PLIST
# iCloud/Finder metadata copied into a build artifact invalidates code signing.
# Clear it only from this generated app bundle, never from source or user data.
xattr -cr "$TASK_APP"
codesign --force --deep --sign - --identifier local.talkie.preview "$TASK_APP"
codesign --verify --deep --strict "$TASK_APP"
mkdir -p "$TASK_ROOT/dist"
if [ -d "$TASK_ROOT/dist/Talkie Preview.app" ] && [ ! -L "$TASK_ROOT/dist/Talkie Preview.app" ]; then
    mv "$TASK_ROOT/dist/Talkie Preview.app" "$TASK_ROOT/dist/Talkie Preview-cloud-copy-$(date +%Y%m%d-%H%M%S).app"
fi
ln -sfn "$TASK_APP" "$TASK_ROOT/dist/Talkie Preview.app"
printf 'Built %s\n' "$TASK_APP"
