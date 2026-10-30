# Source snapshot verification

**Current update: 1.1.5, build 7. Standalone checks, packaged release build and fresh source-copy compilation verified on 30 October 2026.** All results below are from the current public source; no earlier pass is inherited.

Environment: Apple Silicon, Swift 6.4, macOS 27 SDK, Command Line Tools. Full Xcode/XCTest is unavailable.

| Check | Current result |
| --- | --- |
| `scripts/test-core.sh` | 10 checks passed; exit zero; production history/Project Kit code and temporary SQLite files |
| `scripts/test-hotkey.sh` | 110 checks passed; exit zero; no global shortcuts registered or keyboard events monitored |
| `scripts/test-signal.sh` | 12 synthetic audibility checks passed; exit zero |
| `scripts/test-capture.sh` | 96 checks passed; exit zero: 82 repeated-input, 9 capture-configuration and 5 production-writer checks |
| `scripts/build-app.sh` | Release build passed; strict ad hoc signature verification passed; original icon, bundled cue and third-party notices present |
| Fresh source-copy build | Release compilation passed with an empty SwiftPM scratch directory and dependency caching disabled; source hashes match the publication candidate |
| Bundle metadata | Verified 1.1.5/build 7, `local.talkie.preview`, Dock-capable identity and original icon; bundled cue bytes match the source |
| Publication candidate and Git-history secret scans | Gitleaks 8.30.1 found no secrets in the publication candidate or Git history; scans use the default rules without comment-based bypasses |
| Source/privacy review | 46 publication files reviewed; identifier, artifact and isolation checks passed; no runtime files or private assets included, and the sole audio asset is the unchanged synthetic cue |
| Portfolio illustration | Retained original vector with explicit synthetic/privacy captions; not a screenshot or recording |
| `swift test` | Not run: full Xcode/XCTest unavailable in this Command Line Tools environment |

**228 standalone checks passed in fresh runs, and both release compilations passed.** The packaged preview also passed strict signature verification. The capture script's three groups include the 9 new configuration-policy regressions. The clean source-copy build used no prior build artifacts. Both compilations emitted the existing Command Line Tools linker search-path warnings and exited successfully. Standalone harnesses do not establish model inference or running-app behavior.

## Build and runtime evidence are separate

The source changes target compatible-engine configuration notifications, truthful interruption receipts and decoder handling of short/final audio windows. Synthetic capture-policy checks do not establish natural-voice completeness. Real-model testing of subsecond speech and final words is a separate check from the standalone count; record its result independently, including whether networking was disabled.

The isolated preview was **not installed or launched** during this update. No live microphone, editor insertion, model download or running-preview acceptance was performed on 30 October 2026. Dock/reopen, custom chime, nonblocking quiet outcomes, offline cold start and native/browser insertion remain manual acceptance. See [REVIEW.md](REVIEW.md).

No other installation's permissions, recordings, transcripts or model assets count as acceptance evidence for this preview. Shared reports should contain only sanitized environment details and pass/fail observations, not raw audio, history databases or private text. Secret scans cover only the exact scope scanned and do not replace review of the publication diff.
