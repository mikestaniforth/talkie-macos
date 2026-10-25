# Source snapshot verification

Checked on 25 October 2026 using Swift 6.4 and the macOS 27 SDK from Command Line Tools on Apple Silicon. The current source builds preview version 1.1.4, build 6.

| Check | Result |
| --- | --- |
| `scripts/test-core.sh` | 10 checks rerun and passed for 1.1.4 against production history/kit code and temporary SQLite files |
| `scripts/test-hotkey.sh` | 110 checks rerun and passed for 1.1.4, including modifier event/state transitions; no global shortcuts registered or keyboard events posted |
| `scripts/test-signal.sh` | 12 synthetic checks passed for 1.1.3 and retained for unchanged code; optional external audio fixtures not supplied |
| `scripts/test-capture.sh` | 82 signal checks and 5 production writer checks passed for 1.1.3 and retained for unchanged code, including continued writing after a quality warning; no live microphone recording |
| `scripts/build-app.sh` | 1.1.4 release build and original icon generation passed; ad hoc `codesign --verify --deep --strict` passed |
| Bundle metadata | Version 1.1.4, build 6, `local.talkie.preview`, Dock-capable `LSUIElement=false`, icon present and signature valid |
| Source privacy | Generic examples and separate preview identity; runtime audio, history and model files remain excluded. Review the exact publication diff before publishing. |
| Secret scans | Fresh Gitleaks 8.30.1 scans of the current working tree and existing single-commit history found no secrets |
| Portfolio illustration | Original SVG uses synthetic content only |

**219 passing automated checks are represented: 120 rerun for 1.1.4 and 99 retained from 1.1.3.** The signal and capture production sources, harnesses and test scripts were verified unchanged by file hashes; those scripts were not rerun for this update. The recorded builds include Command Line Tools linker search-path warnings; build and signature verification still succeed. Capture harness compilation also reports SDK deprecation warnings for `audioUnit` and `installTap`.

Full Xcode/XCTest is not available in the preparation environment, so `swift test` was not run. The standalone checks complement a full XCTest run; they do not replace it. A future migration from the deprecated capture APIs remains work to do.

The isolated preview was not installed or launched during this source update. No live microphone, natural-voice transcription, model download or text insertion was exercised for this preview. Those remain manual acceptance checks in [TESTING.md](TESTING.md), alongside the unresolved issues in [STATUS.md](STATUS.md). Source-level Dock and HUD changes also require running-preview acceptance checks before claiming their live behavior is verified.

The custom chime picker, playback, local-copy lifecycle and nonblocking quiet/no-speech outcomes (including valid zero-frame captures) also need manual acceptance in the isolated preview. Existing standalone checks do not establish those user-facing behaviors.

Secret scans and manual privacy reviews cover only the files and history actually inspected. Review the exact commit and any later changes before publication.
