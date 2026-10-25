# Security and repository hygiene

No application API key is required. Keep credentials, local model downloads, recordings, histories, preferences and diagnostics outside this repository. `.gitignore` reduces accidental inclusion; it does not remove files already tracked by Git.

Before publishing changes, inspect `git status`, the exact diff and any new binary assets. Scan the files to be published with a secret scanner, and review source examples and file metadata for personal information. If publishing an existing repository, scan all commits and references as well. A clean file scan cannot prove that an arbitrary earlier Git history was safe.

Do not put credentials or private user recordings into a public issue. Until a private reporting channel is configured, keep any security report free of sensitive reproduction data.

[PRIVACY.md](PRIVACY.md) explains local storage, broad macOS permissions, clipboard exposure and network boundaries.
