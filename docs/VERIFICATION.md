# Source snapshot verification

Checked on 25 October 2026 with an Apple Silicon Mac and Command Line Tools.

| Check | Result |
| --- | --- |
| `scripts/test-core.sh` | 9 checks passed against the production history/kit code and temporary SQLite files |
| `scripts/test-hotkey.sh` | 43 checks passed; no global shortcuts registered or keyboard events emitted |
| `scripts/test-signal.sh` | 12 synthetic signal checks passed; optional external audio fixtures not supplied |
| `scripts/test-capture.sh` | 17 synthetic repetition checks and 5 production writer checks passed; no live microphone recording |
| `scripts/build-app.sh` | Release app built; ad hoc signature verification passed |
| Source privacy review | Neutral examples; personal identifiers, private notes and runtime data excluded |
| Gitleaks 8.30.1 | No secrets detected in the prepared publication files |
| Portfolio illustration | SVG XML and local links checked; rendered and visually inspected; synthetic content only |

**86 automated checks passed.** XCTest was not run because full Xcode/XCTest is not available in this environment. The release build emits Command Line Tools linker search-path warnings; build and signature verification still succeed. Audio capture uses APIs deprecated in the current SDK, so a future SDK migration remains work to do.

The isolated preview was not installed or launched during this preparation. No live microphone, natural-voice transcription, model download or text insertion was exercised for this snapshot. Those remain manual acceptance checks in [TESTING.md](TESTING.md), alongside the unresolved issues in [STATUS.md](STATUS.md).

Secret scans and manual privacy reviews cover the prepared source files at this date; review future changes and any future Git history before publication.
