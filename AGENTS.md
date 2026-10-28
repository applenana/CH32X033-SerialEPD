# Work checkpoints

Before starting a new work session, inspect `git status` and commit existing
project progress with an accurate checkpoint message before editing files.
If the tree is already clean, record the current commit; do not manufacture an
empty change. Never include secrets or build caches. This is the user's explicit
workflow preference. Do not rewrite history or reset unrelated edits.

GitHub upload requires a configured remote. Do not invent a repository URL;
report when only a local commit is possible. Do not push unless requested.

# Local build delivery

By user request, compile in place and provide the Windows EXE and Android APK
paths. Do not package ZIPs or run `tools/package_app.py` unless explicitly asked.

# Verification

The firmware and application share SEP/1 and `docs/protocol-vectors.json`.
Run `python tools/test.py` for native C firmware tests. In `app`, run
`flutter analyze` and `flutter test`. The firmware integration tests load the
native simulation built by the Python test command; they must not be skipped
when reporting end-to-end software verification. Real hardware validation must
be reported separately from simulation.
