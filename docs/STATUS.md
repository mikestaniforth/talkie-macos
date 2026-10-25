# Preview status

This is an experimental portfolio source snapshot of a native macOS dictation application. It is suitable for code and product review; it is not a notarised consumer release.

Implemented: custom shortcut recording, hold/toggle dictation, optional activation cue and volume, input selection and meter, local Whisper recognition, verified model setup, SQLite recovery history, explicit Project Kit corrections/framing, and guarded clipboard insertion.

## Known limitations

- Longer USB microphone captures have intermittently repeated earlier audio in development testing. This also occurred through an independent macOS capture API. The underlying cause is unresolved. A repeated-PCM guard stops affected captures and retains recoverable audio; it does not establish universal microphone compatibility.
- Automatic insertion depends on the target app exposing a stable accessible text field. Browser composers, secured fields and unusual editors need individual verification. When delivery cannot be confirmed, use the saved take and copy it manually.
- Natural voice, long-session reliability, sleep/wake behavior, offline cold starts and a broad application/input matrix need further acceptance testing. Previous private-build tests are not proof that this isolated preview has passed them.
- Command Line Tools do not include the XCTest module. Standalone harness results are documented separately; they are not a substitute for a full Xcode test run.
- The application is ad hoc signed. Rebuilds may affect macOS permission grants. No Developer ID signing, notarisation, packaged installer or automatic updater is provided.

See [TESTING.md](TESTING.md) for verification commands and manual acceptance steps.
