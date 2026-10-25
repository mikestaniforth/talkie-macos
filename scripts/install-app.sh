#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_APP="$TASK_ROOT/dist/Talkie Preview.app"
TASK_DESTINATION="$HOME/Applications/Talkie Preview.app"
TASK_BUNDLE_ID="local.talkie.preview"
if [ ! -x "$TASK_APP/Contents/MacOS/Talkie" ]; then
    printf 'Build Talkie Preview first with scripts/build-app.sh\n' >&2
    exit 1
fi
TASK_SOURCE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TASK_APP/Contents/Info.plist")"
if [ "$TASK_SOURCE_ID" != "$TASK_BUNDLE_ID" ]; then
    printf 'The built app does not have the Talkie Preview identity. Installation stopped.\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$TASK_APP"
if pgrep -f '/Talkie Preview[.]app/Contents/MacOS/Talkie([[:space:]]|$)' >/dev/null; then
    printf 'Quit Talkie Preview before installing an update.\n' >&2
    exit 1
fi
if [ -e "$TASK_DESTINATION" ]; then
    TASK_INSTALLED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TASK_DESTINATION/Contents/Info.plist")"
    if [ "$TASK_INSTALLED_ID" != "$TASK_BUNDLE_ID" ]; then
        printf 'The destination belongs to another app. Installation stopped.\n' >&2
        exit 1
    fi
    TASK_BACKUP="$TASK_ROOT/dist/Talkie Preview-previous-$(date +%Y%m%d-%H%M%S).app"
    cp -R "$TASK_DESTINATION" "$TASK_BACKUP"
fi
mkdir -p "$HOME/Applications"
ditto --norsrc --noextattr "$TASK_APP" "$TASK_DESTINATION"
codesign --verify --deep --strict "$TASK_DESTINATION"
printf 'Installed %s. Open it manually when ready.\n' "$TASK_DESTINATION"
