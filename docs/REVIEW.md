# Independent technical review

This snapshot is intended for a local source build and a review of capture reliability, recovery and guarded insertion. No project-wide reuse or redistribution license has been selected for the original source or artwork. Third-party components retain their own licenses; keep [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) with the source and local app.

Use a disposable document and non-sensitive, invented speech throughout. Do not attach real recordings, transcripts or a history database to a public review.

## Clone and identify the source

```sh
git clone https://github.com/mikestaniforth/talkie-macos.git talkie-review
cd talkie-review
git rev-parse HEAD
```

Record the commit under review and read [AGENTS.md](../AGENTS.md), [STATUS.md](STATUS.md) and [PRIVACY.md](PRIVACY.md). Keep local changes separate from the reviewed commit. The current update is version 1.1.5, build 7; [VERIFICATION.md](VERIFICATION.md) records which checks actually ran.

## Test and build

Use an Apple Silicon Mac with **Swift 6 and the macOS 26 SDK or newer**, normally Xcode 26 or compatible Command Line Tools. The runtime deployment target is macOS 14, but the build host must support its developer tools. An older SDK cannot compile the guarded native glass API.

```sh
xcode-select -p
swift --version
xcrun --sdk macosx --show-sdk-version
scripts/test-core.sh
scripts/test-hotkey.sh
scripts/test-signal.sh
scripts/test-capture.sh
scripts/build-app.sh
```

Run `swift test` as well when full Xcode/XCTest is available. If it is unavailable, report that explicitly. See [TESTING.md](TESTING.md) for coverage and toolchain selection. The first build needs internet for pinned Swift Package Manager dependencies. These commands use synthetic fixtures, build and verify the app; they do not install, launch, record a microphone or paste text.

The app is generated at `dist/Talkie Preview.app`, linked to a build artifact in `~/Library/Caches/talkie-preview-build/`. Edit the checkout, not the generated source mirror. This is an ad hoc local development signature, not a notarised distribution.

## Install and set up

Quit any running Talkie Preview before replacing it. Then:

```sh
scripts/install-app.sh
open "$HOME/Applications/Talkie Preview.app"
```

The installer checks identity/signature, installs only the preview and does not launch unless explicitly requested. Run one dictation app at a time, or give each a distinct shortcut; they share the clipboard and global shortcut namespace.

In the running preview:

1. Open **Settings → Microphone**. Enable Microphone and text insertion access when prompted. The insertion permission is **System Settings → Privacy & Security → Accessibility**. Confirm both permission labels in the GUI itself.
2. Select the built-in input for the first control test. Check its meter with **Record five-second test**, then listen back with **Play test**. A moving meter or correct duration alone does not establish complete capture.
3. Open **Settings → Speech model**, select a model and choose **Download local model**. The default **Whisper Turbo · Balanced** model is about 630 MB. Wait for verification/loading and **Offline ready**. Setup downloads model/tokenizer files; subsequent recognition uses those local files, without API keys or cloud inference. This preview needs its own download and does not import another installation's model.
4. In **Settings → General**, check the shortcut and hold/toggle mode. In hold mode, wait for the ready cue, speak, then release the shortcut. In toggle mode, press again to finish. Keep the target field selected while recognition completes.
5. Open a new disposable TextEdit document for the first dictation. Use a browser text area for a separate test after the native editor works. Avoid unsent messages, password fields and consequential forms.

The Dock icon and Command–Tab entry are enabled by default. Closing windows leaves Talkie running; the Dock reopens the Library. **Show Talkie in Dock** offers menu-bar-only operation.

### If permissions look enabled but cannot be used

Ad hoc rebuilds can leave macOS recognizing an older app identity. Quit the preview and reopen the installed `~/Applications/Talkie Preview.app`, rather than the cache artifact. Recheck both permission labels in its Settings.

If Accessibility remains stale, remove only the old **Talkie Preview** entry from macOS Accessibility settings, add the current installed preview and enable it, then quit/reopen the preview. For Microphone, check that this preview's switch is enabled and use the app's permission request when available. Follow any macOS relaunch prompt. Do not reset every application's permissions or grant access to a different installation.

An enabled system switch, a registered shortcut or a terminal `--self-check` result does not prove that the GUI can capture or insert. Check a fresh take and its delivery state independently. Report a persistent mismatch with sanitized app/version and permission states.

## Manual review matrix

Record **Pass**, **Fail** or **Not tested** for each case. Use invented phrases, listen to the entire saved audio and compare locally with the transcript; report observations without uploading either.

| Case | What to check |
| --- | --- |
| Built-in input control | Five-second test, a short sentence and a longer take with pauses remain captured through normal stop. |
| Direct USB control | Repeat the same tests with a USB microphone connected directly, before testing a dock. Keep input selection explicit. |
| USB through dock | Compare the same microphone/cable through the dock. An observed repeating-input path remains unresolved; direct and built-in controls help distinguish source capture from app behavior. |
| Compatible configuration change | A benign notification with a running engine, unchanged format and compatible known route should not truncate the take. A normal test may not produce this notification; mark Not tested if it cannot be observed. |
| Real interruption | Disconnect the selected input during a disposable take. Audio remains available, the cause is reported as an interruption and no suspect text is inserted. Do not interrupt another application's recording. |
| Under-one-second utterance | Dictate a complete short word in under one second. Compare actual captured audio and recognition; successful recording alone does not establish that the decoder retained the word. |
| Thirty-second boundary | Make a take with a complete final word beginning just after 00:30 and ending before 00:31. For a precise regression, use disposable synthetic audio with a word spanning 30.0–30.9 seconds. Check both opening and ending locally; approximate live timing is a separate observation. |
| Quiet/no speech | Brief accidental activation or quiet input produces a calm timed receipt, retains the take and allows the next shortcut without an error alert. Retry as a separate case. If capture itself was interrupted, check the initial result retains that interruption reason instead of a gain suggestion. |
| Native editor | Dictate into disposable TextEdit. Verify visible text and receipt separately: **Inserted**, **Paste attempted** and **Ready to copy** mean different things. |
| Browser field | Repeat in a disposable browser text area or scratch editor, recording browser/editor type. Do not assume the native result transfers. |
| Focus/caret protection | Change field, caret or text while recognition runs. Unsafe or unconfirmed delivery leaves saved words available for manual copying. No Return or Send event should occur. |
| Suspect capture recovery | If repeated-input warning occurs, capture continues until stopped, warning/audio persist and automatic insertion is blocked. An audible local draft may be saved for review; Retry does not erase the warning. Missing source audio cannot be recreated. |
| Local history | Raw text survives corrections/framing. Test playback, Retry, Copy, pinning and deletion with disposable entries. Clipboard insertion replaces the previous clipboard and does not restore it. |
| Interface and shortcuts | Check hold/toggle, custom shortcut persistence, early release, modifier-plus-typing, Dock/reopen and the capsule in light/dark and accessibility appearances. |
| Activation chime | Choose non-sensitive local audio up to 10 seconds/5 MB; Preview, volume, cancel, relaunch and Use default preserve the intended selection. Missing/unplayable custom audio falls back to the bundled cue. Do not share a personal sound asset. |
| Offline recognition | After model setup, disconnect networking, relaunch and test recognition using the installed model. Record model-ready time and transcription outcome separately. |
| Sleep/wake | With only disposable work active, check idle recovery and a deliberately interrupted take. Distinguish stopped capture from ordinary quiet input. |

If a dock route repeats audio, stop relying on its transcript and compare a direct/built-in control. Keep the saved take for local diagnosis. A quality check cannot reconstruct speech the input did not deliver; a warning-free take is not proof of completeness.

## Report without private data

Use this template. Share sanitized descriptions and synthetic reproduction steps, not raw recordings, transcript text, databases, device identifiers, local user paths or unreviewed logs. Screenshots must use synthetic content and hide unrelated applications. Security findings belong through the process in [SECURITY.md](SECURITY.md).

```text
Source commit:
Preview version/build:
macOS / Mac architecture:
Swift version / SDK / full Xcode or Command Line Tools:
Standalone script results (actual counts and failures):
swift test: Pass / Fail / Unavailable (reason)
Release build / signature: Pass / Fail
Installed and manually launched: Yes / No
GUI Microphone / insertion permission states:
Model choice / ready before test / networking state:
Input category: Built-in / USB direct / USB through dock
Editor category and version: Native / Browser
Shortcut mode: Hold / Toggle
Matrix results: Pass / Fail / Not tested for each case
Reproduction steps using disposable synthetic content:
Observed outcome: capture / transcript / delivery receipt separately
Expected outcome:
Recovery available: audio / raw text / prepared text / none
Remaining uncertainty:
```

Check command output for private paths before sharing it. Exact repeated PCM, complete capture, transcription accuracy and editor acceptance are separate findings; report only what was observed. A sanitized review can be shared as a [new review issue](https://github.com/mikestaniforth/talkie-macos/issues/new).
