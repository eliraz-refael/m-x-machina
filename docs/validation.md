# Prototype validation

Validated locally on 2026-10-01 with Emacs 31.1 (SQLite enabled), the installed agent-shell, and the
installed ACP and shell-maker dependencies. The supported minimum Emacs version
is declared as 29.1; a minimum-version CI run is still needed before release.

All 81 deterministic tests passed (54 registry/UI/archive/diagnostic/recovery tests,
10 ACP integration tests, 11 EAT integration tests, 4 vterm integration tests,
and 2 transcript tests).
The suite exercises:

- Worktree reassociation and branch acceptance preserve agent/account identity,
  unread/model/folder metadata, prior failures, run history and dirty Git files.
  A real linked worktree moved with Git can be reassociated without recreating it.
- Recovery cancellation, including a cold registry with saved live observations,
  changes no records. Invalid targets, confirmation-time checkout/record changes,
  starting/running agents and lingering backend processes are rejected. A write
  failure rolls back; unchanged associations do not prompt or write.
- Old eshell jobs and drafts retain their directory; a relocated agent gets a new
  associated shell. Diagnostic recovery refreshes the displayed association.
- EAT resumes from a relocated checkout with the original conversation ID/account.
  A path-bound ACP fixture rejects relocated history; the guarded transport sends
  no replacement session/new request. This does not establish real provider
  history portability.

- Diagnostic explanations for missing profiles/executables/dependencies,
  configuration errors, missing worktrees, branch mismatches, process exit,
  missing SessionStart and inactive hook polling/event files.
- Diagnostic inspection of a closed registry preserves saved live observations,
  conversation IDs, runs and unread flags without opening the manager or migrating.
  A missing registry is not created. ACP client factories are never invoked.
- Diagnostic refresh/copy/return preserves window count and unsent buffer text;
  copies exclude error, argument and environment canaries while retaining a useful
  failure classification. No event consumption or agent launch occurs.

- SQLite reopen with durable profile, worktree, and conversation identity.
- Schema v1/v2 upgrades preserve live identities and observations; schema v3
  archive flags survive restart. Archived agents leave active counts and views.
- Archive restore via RET (including Evil) does not launch an agent; explicit
  resume retains its conversation. Running archive/delete requires stop approval;
  cancellation does not stop processes or change records.
- Transactional record/run deletion rolls back on failure, preserves worktrees,
  history files and buffer text, and ignores delayed events for deleted records.
- Agent/account/interface selection without changing saved profile identifiers.
- Separate per-agent eshell buffers, draft preservation on revisit, and no
  agent launch or status changes when opening an associated shell.
- Real vterm native-module launch, quoted command paths, account environment,
  exact-ID resume, permission states, unread output, exit and failed-setup cleanup.
- Vterm fullscreen scrolling during streaming and classic scrollback in copy
  mode; lifecycle and fullscreen checks also passed with Evil enabled.
- Registry ownership with create-lockfiles disabled, including rejection of a
  second Emacs process without changing the first owner's live state.
- Prefix-sibling folder ordering, name visibility at deep nesting, sidebar hook
  lifetime, cache-only TAB expansion and visible-only animation header refreshes.
- Empty model observations preserving the last known model; direct ID lookup.
- Failed EAT setup hooks releasing process, timer and temporary files; normal
  stop/exit also releasing temporary hook files without deleting conversation history.
- A streaming alternate-screen terminal with virtualized history: page/wheel
  navigation reaches older output while subsequent frames preserve its viewport;
  oldest/latest controls and conservative unread tracking work. The same test
  passes with Evil enabled and confirms insert-state editing keys remain intact.
- Ordinary terminal output larger than EAT's default 128 KiB remains accessible;
  scrolling back retains the reader's point while more output arrives.
- Transcript command-envelope filtering and stale indicators without moving text
  or point; explicit refresh clears the indicator.
- Optional worktree creation on a new branch, durable session association, and
  preservation of the source checkout's branch and uncommitted files.
- Branch/path collisions and invalid names/profiles rejected; cancelled prompts
  create no worktrees. A registry failure reports the retained worktree location.
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
- Sidebar selection and expanded details surviving refresh without launches.
- Status counts with stopped/failed process state taking precedence over activity.
- Conversations filling the main area without splitting it, with a persistent sidebar.
- Per-agent state labels and distinct working-directory paths.
- Closing a conversation, including from focus, restoring editor splits without losing drafts.
- Conversation switching without losing drafts; focus restoring window geometry and selection.
- Failed focus initialization leaving the existing layout intact.
- Online v1-to-v2 migration preserving a live run and its conversation ID.
- Nested/empty folders, agent renaming, unread flags and reported models surviving registry reopen.
- Collapsed folder activity and unread summaries; navigation without launches.
- Unread acknowledgment requiring the selected conversation's latest output;
  stale/ended transports cannot create new unread output.
- Configurable continuous reading delay: brief visits do not accumulate; lost
  visibility/focus, new output and simulated sleep reset it. Explicit acknowledgment
  remains immediate. Timing checks use a controlled clock rather than wall-clock sleeps.
- Cached spinner rendering without SQLite queries and without moving selection.
- Timed `/work` simulation retaining a working state until completion; an ACP
  interrupt cancels a long simulation promptly without changing conversation identity.
- Actual ACP assistant chunks creating unread state while hidden, model metadata
  populating both native header rows, and history replay not creating new unread state.
- Prompt submission through the real ACP transport while focused, retaining focus
  after the reply, restoring the main view, closing without stopping the agent,
  and refreshing live/stop counts.
- Actual EAT subprocesses invoking the production Claude hook helper: working,
  approval, assistant unread state, model updates, stop/reopen/resume, and exit.
- Terminal redraw/history avoiding unread state, partial hook records waiting for
  completion, stopped-run events ignored, and changed conversation IDs stopping
  the process while preserving the original saved ID.
- Missing Claude history launching only an explicit resume request, never a new one.
- Concurrent terminal profiles retaining separate account environments and worktrees.
- Compact sidebar entries, per-agent directories under TAB, and the displayed
  conversation marker staying independent of the navigation cursor.
- Saved transcript snapshots omitting tool payloads/duplicates/partial writes,
  retaining the source terminal and refusing to acknowledge unseen live output.

The optional Evil setup was also loaded and its sidebar navigation, expansion,
open, dashboard and focus bindings checked, including C-c C-z in a conversation.
The EAT layout test also passed with Evil enabled, including normal-state q,
insert-state RET, C-<escape>, and the shared focus/close chords.
The transcript test also passed with Evil's actual V, j, y selection/copy commands.
The 2026-10-01 checkpoint reran the complete 65-test suite, byte compilation, and
four focused Evil checks: archive restore, EAT fullscreen scrolling, vterm
fullscreen scrolling, and transcript selection/copy. All passed.

REC-1 reran all 72 tests and byte compilation with warnings as errors. Its new
diagnostic refresh/copy/return test also passed with Evil enabled. The view was
loaded into the user's running Emacs and checked against all three saved records:
it distinguished an unavailable demo profile, a configured stopped ACP agent
whose executable was not declared, and a configured stopped EAT agent with its
executable available. No agents were running or launched during that check.

REC-2 reran all 81 tests and byte compilation with warnings as errors. The new
`W` recovery flow also passed with Evil enabled. Full real-provider restart and
relocated-history pilots remain outstanding.

The user successfully stopped and resumed a real Claude EAT conversation, with
the saved ID and on-disk transcript confirmed. A full Emacs restart with the live
provider has not been performed during validation.

Both fixtures use local Python, not a commercial model. Claude Code 2.1.278's CLI
flags were checked locally and hook schemas against the official documentation.
Real Claude/account-profile
compatibility needs an interactive pilot with the user's configured backend.
There is no background host or PR/CI integration in this slice. Crash-time cleanup
of arbitrary backend descendants is not verified.

Byte compilation runs with warnings treated as errors. Earlier validation found
the local macOS `make` launcher unavailable because of an unaccepted Xcode license;
the equivalent Emacs commands were executed directly for this checkpoint without
changing system configuration.
