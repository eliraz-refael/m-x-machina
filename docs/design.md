# M-x Machina: session management design

This document records the intended full design. The README describes the current
v0.1 implementation: an SQLite registry, existing or newly created worktrees,
agent-shell/ACP and Claude Code/EAT adapters, and explicit conversation restoration. Background hosting and PR/CI
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

The overview uses a dedicated native side window, with conversations filling
the adjacent editing area. The full table remains available separately. Expanding
sidebar entries is read-only; opening or focusing a stopped conversation is an
explicit start/resume action. A frame parameter holds the temporary window
configuration during focus. A separate frame parameter retains the editor layout
from before opening a conversation. Closing restores that layout without stopping
agents or killing conversation buffers; focus can be nested inside this view.

Lifecycle observations refresh the overview and cached modeline counts together.
The UI distinguishes working, ready, approval, starting, stopped, unknown and
error, with process state taking precedence over stale activity. It does not
infer questions or task completion from conversation text. Each sidebar entry
reveals its recorded worktree directory under TAB. Collapsed entries occupy one
row, with a subtle active-conversation background independent of sidebar cursor
navigation. Colored dots or spinners convey status; TAB reveals the full label.
Deep indentation is capped visually, and hover retains the complete folder path.

Schema v2 adds logical folder paths, explicit empty folders, a per-session unread
flag, project label and last reported model. Folder paths are UI organization;
they never become filesystem operations. Every ancestor is stored, with no fixed
depth limit. Component-wise ordering keeps descendants beside their parents even
when sibling names share a prefix. Moving/renaming agents does not alter backend
identity or worktrees. Empty model notices preserve the last reported model.

Schema v3 adds an archived flag. Active listings and counts exclude archived
records; the archive view restores records without starting a process. Archiving
or deleting a running agent requires explicit stop authorization. Deletion removes
the session and its run records transactionally, keeps worktree/history files,
and detaches retained buffers from the deleted ID. Late lifecycle events for a
deleted ID are ignored. Migrating an already-open registry preserves live states.

Backend display notices use a small normalized boundary: `message` for new
assistant output and `metadata` for reported model information. Only the current
live run can update these fields. The agent-shell adapter suppresses initialization
replay and separates message chunks from thought/tool output. The shared Claude terminal bridge runs
Claude Code with a chosen UUID, confirms it through SessionStart, and resumes by
that exact ID. Private per-run hook logs feed lifecycle, message and model events;
only submitted turns produce unread state. No terminal text is parsed. Account
environments are local to the subprocess; hook settings are supplied per launch.
Run files are removed after stop, exit or failed setup, once the process is gone.
Colors, folders, unread state and native Emacs
headers do not depend on ACP or parse terminal output.

Evil normal/visual states use EAT's Emacs navigation mode. A managed terminal's
navigation map routes page and wheel scrolling to Claude when EAT's
public alternate-display predicate is true. Ordinary scrollback uses Emacs
navigation. The map is buffer-local and precedes terminal and Evil input maps;
Evil insert-state editing chords remain intact. While browsing fullscreen
history, the fixed prompt does not count as seeing the latest output; explicitly
jumping to the latest output restores read acknowledgment.

A separate, explicitly refreshed transcript snapshot reads only the selected Claude session's saved
user/assistant text, so terminal redraws cannot disturb selection. It retains the
agent association for the sidebar background but never auto-acknowledges live
output. Internal command envelopes are omitted. New messages mark the snapshot
stale without changing its contents or selection; explicit refresh clears it.

Activity and unread state are independent. Automatic read acknowledgment requires
the selected conversation to show its latest output in an active frame for a
continuous configurable interval (5 seconds by default). Window/buffer changes,
lost visibility/focus, new assistant output, and long event-loop gaps reset the
countdown. Time is not accumulated across visits. A user can also explicitly
mark a session read immediately. The spinner renders cached state and does
not query SQLite. A short UI heartbeat animates working agents and checks unread
visibility; it stops when neither working nor unread sessions remain. Header
animation visits only visible registered conversation buffers, and sidebar
window observers are removed when the sidebar closes or the manager shuts down.

Build the dashboard as an ordinary Emacs mode with completion and commands that
also work without the dashboard. Session context should carry into file
navigation, project commands, and Magit. Evil bindings and Doom workspace support
belong in optional integrations.

Keep the terminal backend separate from agent identity and the process host.
Select the initial interactive transport after verifying reliable conversation
identity capture and resume. EAT, vterm and agent-shell/ACP share the transport
boundary. Creation groups profiles by agent, account and interface, while the
registry retains the existing durable profile IDs. EAT and vterm share Claude's
hooks, resume flags and account environment. A separate per-agent eshell starts
in the worktree and preserves its shell state on revisit; it is not a managed
agent process and does not acknowledge agent output.

## Remaining decisions and validation

The [backlog](backlog.md) tracks implementation priorities and acceptance checks.

- Live provider pilots; identity, resume, and events have been validated with
  deterministic ACP and actual EAT/vterm fixtures, plus a real Claude EAT
  stop/resume pilot. Full real-provider restart and broader interface validation
  remain open.
- External process host for optional background execution and its supported
  platforms; verify terminal reattachment and event capture while Emacs is closed.
- Confirm the proposed default of stopping agents with Emacs.
- Terminal adapters for CLIs beyond Claude Code.
- Minimum-version validation for the declared Emacs 29.1+ SQLite requirement.
- Final package name.

The next milestone is recovery and diagnostics. Extend the validated session
lifecycle before adding more backends or automatic orchestration.
