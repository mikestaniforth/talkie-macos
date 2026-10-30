# Preview status

This is an experimental native macOS dictation source snapshot, shared for local builds and technical review. It is not a notarised consumer release. The current update is **1.1.5, build 7**. See [VERIFICATION.md](VERIFICATION.md) for fresh automated results and the separate manual acceptance limitations.

## Current behavior and changes

The preview includes custom shortcut recording, hold/toggle dictation, an optional bundled or custom local chime with preview and volume, input selection and meter, local Whisper recognition, verified model setup, SQLite recovery history, explicit Project Kit corrections/framing and guarded clipboard insertion.

The original icon appears in the Dock and Command–Tab by default, with a persisted General setting for menu-bar-only operation. Closing windows keeps the app running; reopening from the Dock shows the Library. The compact recording capsule provides input level, elapsed time and Stop, followed by processing and delivery/recovery receipts. Appearance and accessibility surfaces are described in [DESIGN.md](DESIGN.md).

The 1.1.5 source update addresses three specific paths:

- An audio-engine configuration notification no longer ends a take merely because a notification occurred. Capture can continue when the engine is running, its format is unchanged and its known input route remains compatible. A stopped engine, changed format or changed/lost known route still interrupts. If route information is unavailable, the policy uses running state and format; device-disconnect monitoring remains separate.
- A take interrupted by capture retains that interruption reason and interrupted status when recognition subsequently reports silence or quiet input. It should not substitute a misleading input-gain suggestion for the interruption.
- Explicit `windowClipTime: 0` disables the pinned decoder's short final-window exclusion. This addresses complete subsecond utterances and a final word in a remaining window of one second or less, including just after a 30-second boundary. It does not guarantee that every short utterance will be recognised correctly.

Ordinary quiet-input and no-speech outcomes retain the take, return to idle immediately and show a brief overlay receipt. They do not open a blocking error alert. Unexpected storage, model and other failures remain visible for recovery.

## Known limitations

- A development input path reproduced exact repeated PCM when a USB microphone was connected through a dock; a direct connection provided a useful control. The dock path still needs isolation and broader testing. Do not infer that every dock or microphone is affected, or that another input path is guaranteed to work.
- A repeated-input warning allows recording to continue, retains the captured file and blocks automatic insertion of that suspect take. An audible suspect take may produce a local draft labelled for review. Retry can attempt recovery again, but neither operation can reconstruct speech the input never delivered. Listen back and review recovered text before copying.
- Automatic insertion depends on the target app exposing a stable accessible field. Native editors and browser composers need separate checks. **Paste attempted** does not mean the editor accepted the text; an unconfirmed take remains available for copying.
- Long natural-voice sessions, sleep/wake, offline cold starts and the input/editor matrix still require acceptance in this isolated preview. Testing another installation does not establish that this preview has passed.
- The minimum build SDK is macOS 26 even though the deployment target is macOS 14. Older supported systems use a material overlay fallback. Apple Silicon is the intended configuration; other configurations are not established by the current evidence.
- The application is ad hoc signed. Rebuilds may invalidate macOS permission grants. No Developer ID signature, notarisation, packaged installer or updater is provided.
- Full Xcode/XCTest and standalone harnesses are separate checks. A Command Line Tools-only run cannot claim XCTest coverage.

The intended sharing purpose is local source builds and technical review. No project-wide reuse or redistribution license has been selected for the original code or artwork. Keep the [third-party notices](../THIRD_PARTY_NOTICES.md) with the source and any local application copy.

See [REVIEW.md](REVIEW.md) for an independent reviewer workflow and [TESTING.md](TESTING.md) for verification commands.
