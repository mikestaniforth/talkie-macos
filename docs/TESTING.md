# Building and verification

See [VERIFICATION.md](VERIFICATION.md) for the dated results of this source snapshot.

## Requirements

- macOS 14 or newer; Apple Silicon is the intended runtime configuration.
- Swift 6 toolchain. The package uses Swift 5 language mode.
- Internet for initial dependency resolution and the separately requested model setup.
- Full Xcode for XCTest. The standalone harnesses also work with compatible Command Line Tools.

## Automated checks

Run from the repository root:

```sh
scripts/test-core.sh
scripts/test-hotkey.sh
scripts/test-signal.sh
scripts/test-capture.sh
scripts/build-app.sh
```

These checks use temporary synthetic fixtures. They do not register global hotkeys, record the microphone, install or launch the app, or insert text into another application. The capture harness exercises the production file writer with generated samples. With full Xcode, also run `swift test`.

The build script stages a generated mirror outside the checkout to avoid cloud-folder metadata and file hydration interfering with compilation and ad hoc signing. `dist/Talkie Preview.app` links to the artifact in `~/Library/Caches/talkie-preview-build/Artifacts/`. Do not edit that mirror. The app is locally signed for development; it is not Developer ID signed or notarised.

## Running the preview

After a successful build, run `scripts/install-app.sh` explicitly to install to `~/Applications/Talkie Preview.app`. It does not launch automatically. Open that app yourself, enable microphone and insertion permissions, choose an input, and install a model in Settings. Rebuilding an ad hoc signed app can require macOS permissions to be granted again.

The preview is isolated by its `local.talkie.preview` bundle ID, preferences suite, Application Support directory and build cache. It does not read another Talkie installation's data or models. Run one dictation app at a time, or choose distinct shortcuts: apps still share the system clipboard and global hotkey namespace.

## Manual acceptance checks

Use a disposable note and synthetic speech content. Do not test in a message you might accidentally send.

1. Record a custom shortcut in Settings; confirm persistence, cancellation and conflict handling. Command–V must remain reserved for delivery.
2. Check the selected input, audible cue and input meter. Record a short sentence, then a longer passage with pauses. Listen back and compare the entire transcript.
3. Test hold and toggle modes, early release, repeated presses, a disconnected input and sleep/wake interruptions.
4. Check insertion in native editors and browser text fields. Move focus, edit text or move the caret during recognition; the app should preserve the take rather than insert into an unexpected destination. Confirm the clipboard now contains the transcript; the previous clipboard is not restored.
5. Confirm raw text remains recoverable after corrections and framing. Retry saved audio, copy text, pin a take and remove a take.
6. After model setup, disconnect networking and verify recognition still works.

Automated checks cannot establish hardware compatibility, natural-voice accuracy or insertion behavior in every third-party application.
