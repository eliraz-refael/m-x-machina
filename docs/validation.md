# Prototype validation

Validated locally with Emacs 31.1 (SQLite enabled), agent-shell 0.75.2, and the
installed ACP and shell-maker dependencies. The supported minimum Emacs version
is declared as 29.1; a minimum-version CI run is still needed before release.

All 15 deterministic tests passed. The suite exercises:

- SQLite reopen with durable profile, worktree, and conversation identity.
- Recovery of prior live observations as stopped/unknown.
- Stale run events and late events after a run ends.
- Conversation mismatch rejection without overwriting the original identity.
- Changed branch and unconfirmed identity launch guards.
- Read-only dashboard rendering with no automatic launches.
- Unknown schema rejection.
- Real agent-shell/ACP initialization, prompt exchange, process stop, and resume.
- Unexpected process exit and reuse of the interactive offline demo.
- Preservation of the same conversation across two separate Emacs processes.
- Unsupported resume and missing backend history, checking the fixture's wire
  log to ensure no replacement conversation request is sent.

The fixture is local Python, not a commercial model. Real Claude/account-profile
compatibility needs an interactive pilot with the user's configured backend.
There is no background host, PR/CI integration, or automatic worktree creation in
this slice. Crash-time cleanup of arbitrary backend descendants is not verified.

Byte compilation runs with warnings treated as errors. The local macOS `make`
launcher was unavailable because of an unaccepted Xcode license; the equivalent
Emacs commands were executed directly without changing system configuration.
