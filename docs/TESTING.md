# Building and verification

See [VERIFICATION.md](VERIFICATION.md) for the dated results of this source snapshot.

## Requirements

- Runtime deployment target: macOS 14 or newer; Apple Silicon is the intended configuration.
- A compatible Swift 6 toolchain with a macOS 26 or later SDK, such as Xcode 26 or compatible Command Line Tools. The source references the native glass API behind a runtime availability check, so an older SDK is insufficient even though the deployment target is macOS 14. The package uses Swift 5 language mode.
- Internet for initial dependency resolution and the separately requested model setup.
- Full Xcode for XCTest. The standalone harnesses also work with compatible Command Line Tools.

The standalone checks and release build were run with Swift 6.4 and the macOS 27 SDK from Command Line Tools. Other toolchain/SDK combinations have not been verified for this snapshot. Systems earlier than macOS 26 use the native material overlay fallback at runtime.

## Automated checks

Run from the repository root:

```sh
scripts/test-core.sh
scripts/test-hotkey.sh
scripts/test-signal.sh
scripts/test-capture.sh
scripts/build-app.sh
```

These checks use temporary synthetic fixtures. They do not register global hotkeys, record the microphone, install or launch the app, or insert text into another application. The capture harness exercises the production file writer with generated samples, including continued writing after a quality warning. The shortcut harness exercises stored choices and modifier event/state transitions without monitoring the keyboard. With full Xcode, also run `swift test`.

The build script stages a generated mirror outside the checkout to avoid cloud-folder metadata and file hydration interfering with compilation and ad hoc signing. `dist/Talkie Preview.app` links to the artifact in `~/Library/Caches/talkie-preview-build/Artifacts/`. Do not edit that mirror. The app is locally signed for development; it is not Developer ID signed or notarised.

## Running the preview

After a successful build, run `scripts/install-app.sh` explicitly to install to `~/Applications/Talkie Preview.app`. It does not launch automatically. Open that app yourself, enable microphone and insertion permissions, choose an input, and install a model in Settings. Rebuilding an ad hoc signed app can require macOS permissions to be granted again.

Launching after installation is an explicit option:

```sh
TALKIE_LAUNCH_AFTER_INSTALL=1 scripts/install-app.sh
```

This launches only `~/Applications/Talkie Preview.app`. Automated source verification does not run the installer or use this option.

The original app icon is shown in the Dock and Command–Tab by default. General settings offers **Show Talkie in Dock** for choosing between that behavior and menu-bar-only operation. Closing windows keeps the app running.

The preview is isolated by its `local.talkie.preview` bundle ID, preferences suite, Application Support directory and build cache. It does not read another Talkie installation's data or models. Run one dictation app at a time, or choose distinct shortcuts: apps still share the system clipboard and global hotkey namespace.

## Manual acceptance checks

Use a disposable note and synthetic speech content. Do not test in a message you might accidentally send.

1. Confirm the Dock icon and Command–Tab entry appear on first launch. Close windows, reopen from the Dock, and verify the Library returns. Toggle **Show Talkie in Dock** off and on, then relaunch and confirm the preference persists.
2. Record a custom shortcut in Settings; confirm persistence, cancellation and conflict handling. Command–V must remain reserved for delivery. Exercise hold and toggle modes, early release, repeated presses, opposite-side modifier keys and using a modifier with another key.
3. Check the selected input, bundled cue and input meter. In General settings, choose a readable local audio chime up to 10 seconds and 5 MB, preview it, adjust its volume and verify it persists after relaunch. Cancel the chooser and try an invalid file; the previous choice should remain. Use **Use default** to restore the bundled cue. Confirm the custom copy stays in this preview's local data folder and no original source path is stored. Record a short sentence, then a longer passage with pauses. Listen back and compare the entire transcript. A moving meter or full file duration alone does not establish complete capture.
4. Check the recording overlay's elapsed time, Stop control and processing/delivery states in light and dark appearance. Enable Reduce Transparency, Increase Contrast and Reduce Motion and verify the surface remains readable and usable without taking focus from the target field.
5. Exercise a disconnected input and sleep/wake interruptions. If a repeated-input warning occurs, verify recording continues until stopped, the captured file remains available, and nothing is inserted automatically. An audible suspect take may produce an automatic draft labelled for review. Listen back and review that draft, or use Retry deliberately, before copying recovered text.
6. Check insertion in native editors and browser text fields. Move focus, edit text or move the caret during recognition; the app should preserve the take rather than insert into an unexpected destination. Confirm the clipboard now contains the transcript; the previous clipboard is not restored.
7. Confirm raw text remains recoverable after corrections and framing. Retry saved audio, copy text, pin a take and remove a take.
8. Record quiet input or a take with no recognisable speech. Verify a brief **Too quiet** or **No speech** overlay notice appears, the take remains in the Library and the next shortcut works without dismissing an error alert. Check the same recovery behavior when Retry produces one of these outcomes. Unexpected storage or model failures should still remain visible for attention.
9. After model setup, disconnect networking and verify recognition still works.

Automated checks cannot establish hardware compatibility, natural-voice accuracy or insertion behavior in every third-party application.
