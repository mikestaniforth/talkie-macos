# Privacy and local data

Talkie Preview performs speech recognition on the Mac. There is no account, hosted backend, analytics SDK, cloud rewriting or application API key in this source snapshot.

## Network boundaries

The first Swift Package Manager build fetches the public dependencies pinned by `Package.resolved`. Model setup explicitly downloads model and tokenizer files from public Hugging Face repositories at pinned revisions and verifies their repository hashes. Model setup requires internet access. Recognition uses installed files, including a local tokenizer adapter; it does not upload recordings or transcripts. No credentials are needed for the public model downloads.

## Stored data

Runtime files are created outside the repository in `~/Library/Application Support/Talkie Preview/`:

| Location | Contents |
| --- | --- |
| `history.sqlite3` and journal files | Raw, corrected and framed transcripts, timestamps, delivery status, selected Project Kit snapshot, target app name and bundle ID, local audio path, persistent capture-quality warnings and errors |
| `Recordings/` | Captured dictation audio |
| `microphone-test.caf` | Most recent microphone test, at the data folder root; separate from history retention, kept until overwritten by the next test or manually removed |
| `Models/` | Downloaded model and tokenizer assets |
| `Sounds/` | A managed local copy of an optional custom activation chime |

Preferences use the separate `local.talkie.preview` UserDefaults suite. This preview does not automatically import another installation's history, preferences or models. Build intermediates and the local application artifact use `~/Library/Caches/talkie-preview-build/`.

Choosing a custom chime reads the selected audio file and copies it into `Sounds/`. The `customActivationSoundFile` preference stores only the managed filename; the original filename and path are not persisted. The audio is not uploaded or added to the repository. **Use default** clears the preference and attempts to remove the managed copy; a local storage failure is reported if removal fails. Cancelling the chooser keeps the previous selection.

History is intentionally recoverable. Current retention keeps unpinned text for 30 days and routine audio for 24 hours; pinned text and unresolved recovery can be retained longer. Successfully transcribed audio can also be removed early when the audio storage cap is exceeded; pinning text does not preserve its audio indefinitely. Retention runs while the app runs. Review the Library and remove items when appropriate. This is not an encrypted vault: macOS user permissions and the Mac's disk encryption govern access to stored data.

## Permissions and insertion

Microphone access allows recording during dictation or a microphone test. Accessibility access supports global modifier shortcuts and reading the intended text field to check whether insertion is safe. These are broad macOS permissions; source is available for inspection.

Text insertion writes a transcript to the system clipboard and emits Command–V once. It replaces the previous clipboard contents and leaves the transcript there; this version does not restore the previous clipboard. It verifies the destination where possible and leaves a saved take for manual copying when verification is unavailable. Clipboard managers and other software with clipboard access may retain copied text. No automatic Return or Send event is emitted. Review the destination before sending a message yourself.

## Sharing diagnostics

Do not attach real recordings, history databases, personal transcripts, full local paths or credentials to public issues. Reproduce problems with synthetic text and recordings, and review any diagnostics before sharing.
