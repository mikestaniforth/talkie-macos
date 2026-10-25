# Talkie

A native macOS dictation beta with on-device speech recognition, guarded text insertion and recoverable local history.

**Experimental portfolio project.** This is source for a locally built preview, not a notarised end-user release. Longer USB microphone captures and compatibility across custom editors remain under investigation. See [current status](docs/STATUS.md).

![Illustrative Talkie Preview interface with synthetic dictation text, a native library and a compact recording overlay](docs/images/talkie-overview.svg)

*Original vector illustration using synthetic text. This is an interface preview, not a screenshot or evidence of a completed recording.*

## The idea

Hold a shortcut, wait for the cue, and speak into the field where you are working. Talkie records locally, checks the captured signal, recognises speech on the Mac and saves the transcript before attempting insertion. When insertion is unavailable, the words remain available to copy.

- **Native and discreet:** menu-bar controls, a compact recording overlay and adaptive system appearance.
- **Your shortcut:** record a key combination or supported modifier-only shortcut; choose hold or toggle activation and an optional ready cue.
- **Local recognition:** WhisperKit runs speech recognition on the device after model setup.
- **Recovery first:** journalled recordings, original and prepared transcripts, playback, retry and explicit delivery states in SQLite history.
- **Guarded paste:** check the destination, make one paste attempt and distinguish confirmed insertion from an unverified attempt. Never press Return or Send.
- **Project Kits:** preferred vocabulary, explicit corrections and prompt frames applied deliberately around your words.

See the [architecture](docs/ARCHITECTURE.md) for the capture, storage and delivery flow.

## Build a local preview

Requires macOS 14 or later, Apple Silicon and a Swift 6 toolchain. Swift Package Manager fetches the pinned dependencies.

```sh
./scripts/build-app.sh
./scripts/install-app.sh
```

The build produces `dist/Talkie Preview.app` with an ad hoc local signature. The installer writes to `~/Applications/Talkie Preview.app` without launching it. Open the preview when ready. In Settings, download the speech model, grant Microphone and Accessibility access, then test with a disposable text field. Recognition works offline after setup; model and tokenizer downloads require a network connection. Run one dictation app at a time, or choose distinct shortcuts to avoid conflicts.

The preview uses a separate identity and local data location:

- Bundle identifier: `local.talkie.preview`
- Data: `~/Library/Application Support/Talkie Preview/`
- Build cache: `~/Library/Caches/talkie-preview-build/`

## Reliability and privacy

Saving and insertion are separate steps. A paste request does not establish that an editor accepted the text. Signal and repeated-audio guards can reject unusable recordings, but cannot reconstruct speech that a device never delivered. Broader application, long-capture and hardware testing is still needed.

Microphone audio and transcripts are processed locally; there is no account or hosted inference backend. Retention and local data protection are documented in [privacy and storage](docs/PRIVACY.md).

Standalone checks exercise the production history, signal, capture and shortcut code. They complement real microphone and editor tests; they do not replace them. See [testing instructions](docs/TESTING.md) and [snapshot verification](docs/VERIFICATION.md) for commands, evidence and limitations.

## Components and rights

Built with SwiftUI, AppKit, Core Audio, SQLite and WhisperKit. Speech models and tokenizer assets are downloaded separately and stay outside the repository.

Third-party components retain their own licenses and notices; see [third-party notices](THIRD_PARTY_NOTICES.md). A project-wide license for the original source and artwork has not yet been selected.
