# Talkie Preview development

This is a native macOS portfolio source snapshot. Keep changes scoped and preserve user work.

- Never commit, push, publish, deploy or install without an explicit request.
- Keep recordings, transcripts, databases, logs, preferences, credentials and model assets out of Git. Use synthetic fixtures.
- Preserve raw transcripts and save before attempting insertion. Never emit Return or Send.
- The preview uses its own bundle identity, preferences, cache and Application Support directory. Do not migrate or open another Talkie installation's data.
- Run the four scripts documented in docs/TESTING.md. Run swift test when full Xcode/XCTest is available; report its limitation on a Command Line Tools only Mac.
- Run scripts/build-app.sh after source changes. Build output is generated; edit this source tree, not the cache mirror. Do not install during automated checks.
- Keep THIRD_PARTY_NOTICES.md with source and application distributions.
- External AI services are outside this version. No API keys or cloud infrastructure are needed.
