# Preview status

This is an experimental portfolio source snapshot of a native macOS dictation application. It is suitable for code and product review; it is not a notarised consumer release.

The 1.1.4 source update includes custom shortcut recording, hold/toggle dictation, an optional bundled or custom local activation chime with preview and volume, input selection and meter, local Whisper recognition, verified model setup, SQLite recovery history, explicit Project Kit corrections/framing, and guarded clipboard insertion.

The app now shows its original icon in the Dock and Command–Tab by default, with a persisted General setting for menu-bar-only operation. Closing a window keeps the app running; a Dock reopen opens the Library. The recording overlay is a compact native capsule with input level, elapsed time and Stop, followed by processing and delivery/recovery receipts. It adapts to appearance, reduced transparency, increased contrast and reduced motion. See [DESIGN.md](DESIGN.md).

Expected quiet-input and no-speech outcomes use a brief overlay notice and return to idle, retaining the take and its recovery status in the Library. They do not open a blocking error alert. Unexpected storage, model and other failures remain visible for recovery.

## Known limitations

- Some microphone input paths have intermittently repeated earlier PCM in development testing. The repeated-audio check warns without stopping the recording, retains the complete captured file and prevents automatic insertion of a suspect take. An audible suspect take can produce a local draft automatically, labelled for review. Retry in the Library can attempt recovery again; review the recording and text before copying. The guard does not repair an upstream stream fault, establish universal microphone compatibility or prove that a take contains every spoken word.
- Automatic insertion depends on the target app exposing a stable accessible text field. Browser composers, secured fields and unusual editors need individual verification. When delivery cannot be confirmed, use the saved take and copy it manually.
- Natural voice, long-session reliability, Dock/reopen behavior, sleep/wake, offline cold starts and a broad application/input matrix need acceptance testing in the isolated preview. Tests of another installation are not proof that this preview has passed them.
- Command Line Tools do not include the XCTest module. Standalone harness results are documented separately; they are not a substitute for a full Xcode test run.
- The application is ad hoc signed. Rebuilds may affect macOS permission grants. No Developer ID signing, notarisation, packaged installer or automatic updater is provided.

See [TESTING.md](TESTING.md) for verification commands and manual acceptance steps.
