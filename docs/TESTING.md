# Building and verification

See [VERIFICATION.md](VERIFICATION.md) for dated evidence and [REVIEW.md](REVIEW.md) for a fresh clone, first-run setup, manual acceptance and a report template. Results from an earlier snapshot do not verify the current source.

## Requirements

- Runtime deployment target: macOS 14 or newer; Apple Silicon is the intended configuration. The build host must also support the selected developer tools.
- **Swift 6 and the macOS 26 SDK or newer**, such as Xcode 26 or compatible Command Line Tools. The package uses Swift 5 language mode. A runtime availability check for native glass does not make an older SDK sufficient to compile it.
- Internet for initial dependency resolution and the separately requested model/tokenizer setup. No account or API key is required.
- Full Xcode for XCTest. Compatible Command Line Tools can run the standalone harnesses and build script, but do not include the XCTest module.

Check the selected tools before building:

```sh
xcode-select -p
swift --version
xcrun --sdk macosx --show-sdk-version
```

If full Xcode is installed but these commands select older tools, choose the intended Command Line Tools version in Xcode's settings. The scripts use the selected `swift` toolchain. The current recorded environment is Swift 6.4 with the macOS 27 SDK; other toolchain combinations are not established by those results.

## Automated checks

Run from the repository root:

```sh
scripts/test-core.sh
scripts/test-hotkey.sh
scripts/test-signal.sh
scripts/test-capture.sh
scripts/build-app.sh
```

The 1.1.5 standalone suite contains **228 checks**: 10 history/Project Kit, 110 shortcut, 12 audibility, 82 repeated-input, 9 capture-configuration and 5 writer checks. The last three groups run through `test-capture.sh`. Consult [VERIFICATION.md](VERIFICATION.md) for the dated actual results. With full Xcode, also run:

```sh
swift test
```

The harnesses use temporary synthetic fixtures and production source. They do not register global hotkeys, monitor the keyboard, record a microphone, download a speech model, install or launch the app, or insert text into another application. Generated audio and file-writer checks do not establish microphone compatibility or natural-voice accuracy. `swift test` remains a separate check even when all standalone checks pass.

The release build stages a generated source mirror outside the checkout to avoid cloud-folder metadata and hydration interfering with compilation and signing. Edit repository sources, not that mirror. `dist/Talkie Preview.app` links to the artifact under `~/Library/Caches/talkie-preview-build/Artifacts/`. The script creates and verifies an ad hoc signature. It is not Developer ID signed or notarised.

## Explicit installation and first run

After a successful build, quit any running Talkie Preview and install deliberately:

```sh
scripts/install-app.sh
open "$HOME/Applications/Talkie Preview.app"
```

The installer verifies the preview identity/signature, installs to `~/Applications/Talkie Preview.app` and keeps a backup when replacing an existing preview. It does not launch automatically. `TALKIE_LAUNCH_AFTER_INSTALL=1 scripts/install-app.sh` is an explicit install-and-launch option; automated checks must not use it.

Follow [REVIEW.md](REVIEW.md) to enable Microphone and Accessibility access, select an input, download and load a local model, and test a disposable field. An ad hoc rebuild can require the installed app's permission grant to be refreshed. A terminal-launched `--self-check` process is not proof that the GUI has the same permission state.

The preview uses `local.talkie.preview` for its bundle identity and preferences, its own Application Support directory including `Models/`, and the separate build cache above. Do not copy another installation's model, preferences or history into it. Apps still share global shortcuts and the system clipboard, so run one dictation app at a time or assign distinct shortcuts.

## Manual acceptance

Use the [input and editor matrix](REVIEW.md#manual-review-matrix) with disposable, non-sensitive speech. In particular, verify:

- Sustained capture through benign configuration notifications; real route loss still stops and retains the take.
- Short words below one second, and a complete final word just after the 30-second decoder boundary ending before 31 seconds.
- Calm no-speech/quiet receipts versus truthful interruption receipts, with the next shortcut immediately available.
- Built-in and direct USB controls before drawing conclusions about a USB dock path.
- Native editor and browser-field insertion, focus/caret changes, and recovery when delivery is unconfirmed.
- Dock/reopen, custom shortcut/chime, accessibility appearance and offline recognition after model setup.

These are running-app acceptance checks. A passing build or synthetic harness does not establish their outcome.
