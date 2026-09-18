# Session management design

This document records the intended full design. The README describes the current
v0.1 implementation: an SQLite registry, existing worktrees, an agent-shell
adapter, and explicit conversation restoration. Background hosting and PR/CI
records below are not implemented yet. The initial schema folds the single
conversation reference into the session and run records; conversation replacement
and forking are not supported.

## Identity and ownership

The core owns a durable session record. A backend adapter reports conversation
identity and performs backend-specific start, resume, interrupt, and stop actions.
The process host owns execution; a terminal or other interactive buffer provides
the UI. Closing a dashboard must not imply stopping its sessions.

Keep three identities distinct:

| Identity | Lifetime | Purpose |
| --- | --- | --- |
| Session ID | Entire managed session | Stable package identity |
| Backend conversation ID | Backend conversation | Resume the correct conversation |
| Run ID | One process launch | Attribute events and reject stale updates |

The session also stores the backend type, account/profile reference, canonical
repository and worktree paths, and branch. A conversation ID alone is not enough
to select the correct backend environment. Store references to profiles, not
credentials. Runtime process handles and Emacs buffers are not durable values.

Reattaching to an already-running process preserves its run ID. If a transport
needs to distinguish reconnects, use a separate connection generation.

A session can have successive conversations only through an explicit replacement
or fork action. Preserve the previous identity and explain that the replacement
is a new conversation. A failed resume must never silently start a new one.

## Optional background execution

Support two execution policies, independent of conversation persistence:

| Policy | When the Emacs process exits | When Emacs starts again |
| --- | --- | --- |
| Stop with Emacs (proposed default) | Stop the managed agent process and its managed child processes | Show the saved session as stopped; resume explicitly |
| Keep running | Leave the externally hosted agent running | Discover and reattach to the existing run if it is still alive |

The user has requested both policies; the default remains a recommendation.
Provide a global preference and a per-session override. Resolve and persist the
effective policy when launching a run, and display it in the dashboard. Changing
the preference applies to future launches, not silent migration of live processes.

The proposed default makes continued execution, tool use, and usage costs an
explicit choice. Both policies retain the conversation ID and worktree. Neither
automatically starts a fresh conversation or replays interrupted input.

Closing a dashboard, terminal view, or client frame is not equivalent to exiting
the owning Emacs process. In daemon mode, stopping the daemon is the exit boundary.
View closure must not accidentally terminate the managed process; the transport
must enforce this independently of buffer lifetime.

For normal Emacs shutdown, attempt graceful interruption and bounded cleanup of
managed processes before forced termination if necessary. Abrupt crashes cannot
rely on Emacs exit hooks; parent-death cleanup needs an OS/process-host mechanism
and must be verified before promising that no managed processes survive a crash.
This policy covers managed processes, not arbitrary jobs an agent starts in an
external service.

Background execution requires a process host that survives Emacs, retains the
interactive session, and captures lifecycle events while Emacs is disconnected.
Unavailable hosting must produce an actionable error, not a silent change in
execution policy. Before starting a replacement process, verify that the old run
has ended; unknown host state must not produce duplicate agents. Reattachment
retains the existing run ID. Restarting after process exit creates a new run ID
and uses the saved conversation ID.

Background mode does not imply surviving a machine reboot, automatically
restarting failed agents, or automatically approving permission requests. An
agent awaiting input can remain waiting until the user reconnects.

## SQLite registry

Use one local SQLite database outside the source checkout, in a configurable
state directory. Proposed logical records:

- Sessions: stable identity, name, backend/profile, repository/worktree, branch,
  active conversation reference, optional execution-policy override,
  creation/update times, and archival state.
- Conversations: session reference, backend conversation ID, profile reference,
  creation time, and any superseded conversation reference.
- Runs: session/conversation references, unique run ID, process-host reference,
  resolved execution policy, lifecycle timestamps, activity observations,
  and exit information.
- PR associations: forge, repository identity, PR identifier and URL, and cached
  review/check observations with retrieval times.

Conversation identity may initially be unknown. Persist it immediately when the
backend reports it; until then show that resumability is unconfirmed. Saving the
conversation reference and associating it with its run should be transactional.
Resume failures must leave the saved conversation identity intact.

Use schema versions and explicit migrations. Initially, one Emacs instance owns
a registry. External hooks report events to an ingestion boundary instead of
depending on the database schema or modifying it directly.

The database is not a replacement for backend conversation storage. Recovery
depends on both the registry and the backend's retained history and credentials.

## Independent status dimensions

- Process: starting, live, stopped, exited, or failed.
- Activity: unknown, working, awaiting approval, or awaiting input.
- Task outcome: unknown or explicitly reported; never inferred from a live
  process, a completed turn, or successful CI alone.
- PR/checks: independent external observations, including unknown or stale data.

Every activity observation carries its source, run ID, and observation time.
Use event ordering or sequence numbers where supported. Reject observations from
superseded runs, and reconcile activity with known process exit. Preserve a
previous observation as history without presenting it as current after restart.

Prefer documented structured lifecycle events or hooks. Represent missing
capabilities as unknown rather than presenting terminal guesses as reliable
status. Hook availability and event semantics require per-backend verification.
External PR/CI state may use bounded asynchronous polling independently of local
agent events.

## Start and resume

1. Load saved sessions without launching agents.
2. Reconcile externally hosted runs and reattach to confirmed live processes
   without launching replacements. Preserve uncertainty if the host is unreachable.
   For stopped runs, continue below only on explicit start/resume.
3. On explicit start/resume, validate the worktree and backend/profile context.
4. For resume, require the saved conversation ID and the adapter's verified
   resume capability. Report missing history or unsupported resume clearly.
5. Create a new run identity and invoke the backend in the recorded worktree.
6. Confirm conversation identity when the backend supports reporting it; flag a
   mismatch as a restoration failure instead of updating the saved ID silently.
7. Attach the interactive buffer and consume events for the active run.

Do not replay a prompt automatically after an interrupted run: its effects may
already have happened. Resuming history does not necessarily resume computation.
Missing worktrees and changed branches need explicit recovery, not silent resets.
Stopping a process, archiving a record, and deleting a worktree are separate actions.

## Emacs integration

Build the dashboard as an ordinary Emacs mode with completion and commands that
also work without the dashboard. Session context should carry into file
navigation, project commands, and Magit. Evil bindings and Doom workspace support
belong in optional integrations.

Keep the terminal backend separate from agent identity and the process host.
Select the initial interactive transport after verifying reliable conversation
identity capture and resume. EAT, vterm, and structured agent interfaces remain
candidates, not promised interchangeable implementations.

## Decisions to resolve before implementation

- First live provider pilot through the initial agent-shell adapter; identity,
  resume, and events have been validated with a deterministic ACP fixture.
- External process host for optional background execution and its supported
  platforms; verify terminal reattachment and event capture while Emacs is closed.
- Confirm the proposed default of stopping agents with Emacs.
- Terminal adapters beyond the initial agent-shell interactive transport.
- Minimum-version validation for the declared Emacs 29.1+ SQLite requirement.
- Final package name.

Start with one end-to-end session lifecycle. Verify identity capture, failed
resume behavior, stale events after restart, and persistence across Emacs
restarts before extending to additional backends or automatic orchestration.
