# Prototype validation

Validated on 2026-10-04 locally and on [GitHub Actions](https://github.com/eliraz-refael/m-x-machina/actions/runs/37234024596).
The complete hosted matrix passes: core checks on Linux Emacs 29.1, 30.2 and 31.1,
and macOS 31.1; full transport checks on Linux Emacs 29.1 and 31.1. Each core job
passes 88 tests, and each full job passes 128 tests with pinned dependencies and
a freshly built native vterm module. All 17 Lisp files compile with warnings
as errors. The required CI gate accepts only successful results from every job.

The 128 deterministic tests cover 79 registry/UI/archive/diagnostic/recovery/board/
attention/action/install cases, 14 ACP integration cases, 12 EAT cases, 4 vterm
cases, 2 transcript cases and 17 messaging cases. The full suite also passes
locally on Emacs 31.1. The transaction checks cover errors, quits, throws and
commit failures; registry writes use an explicit rollback helper because the
Emacs 29.1 built-in transaction macro commits on body errors.

The release runner (`python3 scripts/check --suite all --fetch-deps --build-vterm`)
uses a disposable checkout and isolated Emacs state. An injected compiler warning
was verified to fail the runner. Installation smoke checks exercise plain Emacs
and loading the optional Doom example without Doom installed. Separate real
startup checks were added on 2026-10-06, described below; a real-provider restart
pilot remains outstanding. No personal configuration, installed
package or live Emacs session was changed. See [testing](testing.md) for reproduction.

The suite exercises:

- CLI `whoami` and automatic sender discovery for existing agent processes without
  an inherited ID. A real fixture agent identifies itself and exchanges a message
  through the CLI in both cases. Unknown identity fails explicitly; directory
  sharing, stopped transports and cyclic process metadata cannot misidentify it.
- ACP asynchronous startup retains each agent's own messaging environment while
  preserving its account configuration; two concurrent agents are verified using
  their actual subprocess environments, and the shared profile remains unchanged.

- ACP session listing for title metadata is allowed before/after readiness and
  after turns. Minimal resume retains the original ID; listing after a failed
  resume cannot permit replacement creation. Stopped managed buffers reject
  requests before ACP can auto-start an untracked client.

- Messaging across real agent-shell/ACP, EAT and native vterm transports, plus
  local Emacs socket/CLI JSON round trips and a fixture agent consulting another
  fixture agent with inherited sender identity. Unicode and quoted messages work.
- Busy/approval/visible/draft delivery holds, delayed prompt acknowledgments
  retaining newly typed drafts, and replies staying unread in the UI.
- Correlation rejects mismatched prompts and old runs; explicit request IDs are
  idempotent, pending request cycles are rejected, cancellation affects queued
  requests only, and interrupted requests are never replayed after restart.
- Private message-file permissions, retention of pending records while completed
  records expire, and mailbox write errors disabling messaging without failing a
  healthy backend transport. No real-provider prompt was sent in these checks.

- Contextual actions retain the original target across cursor movement, explain
  disabled actions and revalidate changed/removed records. Archive/delete
  cancellation preserves processes and records. Empty/folder contexts work
  without registry writes, and menu dismissal restores the original layout.
- Menu key dispatch works with plain Emacs and Evil; board opening retains its
  return path. EAT/vterm expose `C-c ?`, and opening/dismissing the menu preserves
  a running vterm conversation.

- Attention navigation prioritizes input/approval requests over unread-only
  agents, preserves creation order, deduplicates and wraps. Idle agents without
  unread output and archived agents are excluded. Separate waiting/unread queues
  work in both directions.
- Sidebar ancestor expansion respects prefix siblings; scoped boards retain their
  filter and select cards without opening them. Resolved requests disappear from
  the queue. Empty queues preserve selection. Dashboard and conversation entry
  points retain drafts, process counts and unread records.

- The board shows every observed state, groups full folder paths, respects
  descendant boundaries and excludes archived agents. Narrow and wide layouts
  retain all cards; long names wrap and unread flags survive navigation.
- Card identity stays selected across state changes and cached reflow. Keyboard
  navigation, failed opens, conversation return and the preceding editor layout
  retain their position and drafts. Rendering/navigation starts no agent.

- Explicit saved-ID retry after restoring a missing terminal profile retains the
  account and conversation, submits no input and makes no replacement launch.
  ACP authentication failure, unsupported resume and rejected history preserve
  the saved ID and send no replacement session/new requests.
- Cancelled retries preserve even a closed registry; missing profiles and missing
  conversation IDs are rejected. Profile or record changes during confirmation
  prevent launch. Recovery guidance/copies exclude error and command canaries.
  Guidance distinguishes known failures from ambiguous missing SessionStart.

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

REC-3 reran all 86 tests and byte compilation with warnings as errors on
2026-10-04. Its diagnostic `R` retry control also passed with Evil enabled.
Profile reassignment is deliberately unavailable: the current registry contains
no verified historical account identity. Guidance supports restoring the
original configuration and explicitly creating a separate agent when necessary;
these tests do not establish account equivalence for profile substitution.

The 2026-10-04 board prototype passed the complete 92-test suite, all six board
tests with Evil enabled, and byte compilation with warnings as errors. It was
loaded into the user's macOS Emacs and rendered against the three existing
agents without changing records or process counts. Visual density and whether
the optional board improves daily use remain user-evaluation questions.

ATT-1 passed the complete 97-test suite, all five attention tests with Evil
enabled, and byte compilation with warnings as errors on 2026-10-04.

UX-1 passed the complete 103-test suite, all six action-menu tests plus the EAT
layout and vterm lifecycle tests with Evil enabled, and byte compilation with
warnings as errors on 2026-10-04.

MSG-1 passed the complete 115-test suite, all 12 messaging checks with Evil
enabled, and byte compilation with warnings as errors on 2026-10-04. The CLI tests use a
private temporary Unix socket and offline fixtures. Server lifecycle hooks are
scoped to each fixture, including failed socket startup; a regression test checks
that no shutdown hook escapes to the test process's default server configuration. Real Claude message delivery,
Stop-hook reply capture and prompt preservation still need an interactive pilot;
fixture results do not establish compatibility with every provider version.

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

The 2026-10-04 Claude ACP fix passed all 119 tests, the three new ACP integration
checks with Evil, and byte compilation with warnings as errors. A real
`claude-code-work` startup reached ready with no prompt sent; its temporary
transport was then stopped. An existing failed session returned backend code
-32002 (`Resource not found`) for its original ID. No replacement was created
for that record. Startup success does not establish a completed real-provider
prompt or restart/resume round trip.

The initial M-x Machina naming pass (superseded by the namespace cleanup)
retained registry paths, existing Emacs commands and CLI environment variables. `mxm` opens the same saved registry, and the old
`scripts/emacs-agents` launcher delegates to `scripts/mxm` without losing process
ancestry. The full 127-test suite includes a peer exchange through that legacy
launcher with no inherited sender ID, plus saved-registry reuse through `M-x mxm`.
Compilation with warnings as errors and all 87 core tests also pass on Emacs 30.1.
No personal Doom configuration, installed packages or live sessions were changed.

The 2026-10-05 namespace cleanup replaces the alias facade with actual
`mx-machina-*` libraries, symbols and autoloads, and removes `mxm.el`. All 89
core tests and 130 full-suite tests pass on Emacs 31.1, with warnings treated as
errors when compiling all 16 Lisp files. Added checks load generated autoloads
in a fresh Emacs with conflicting `emacs-agents.el` and `mxm.el` libraries earlier
on `load-path`, reopen a synthetic registry produced by the pre-rename code,
and call an old-style message service from the updated CLI. Default storage,
profile IDs, conversation IDs and CLI environment variables stay unchanged.
These checks run in disposable copies without loading personal configuration.

## Clean installation checks — 2026-10-06

`scripts/check-install` exercises normal interactive startup through a private
pseudo-terminal, with an isolated HOME, XDG directories, Doom configuration,
package state and registry. It does not use `--batch` to approximate startup.
The generated configuration follows the installation guide; the Doom case
loads the checked-in `examples/doom-packages.el` bundle and `examples/doom.el`.

Local checks on macOS passed plain startup/restart on Emacs 30.1 and 31.1,
and both plain-with-adapters and a new Doom 2.2.4 installation on Emacs 31.1.
Each boot verifies sidebar, board and dashboard access; a second boot recovers
the same saved fixture agent without starting it. The adapter setups load
agent-shell, ACP, shell-maker, EAT and the compiled native vterm module from
the disposable installation. Doom additionally checks Evil motion state,
sidebar RET/j bindings and the leader binding. The plain baseline verifies
actionable errors for absent EAT/vterm packages.

The fresh Doom check uses core revision `59cdaa32ae933469bb6a1fb3cadee8a988c15968`
and its module/package pins with the adapter revisions in `test/dependencies.json`.
Doom fetches upstream recipe indexes: this is not a fully hermetic distribution.
No provider authentication, real model conversation or personal Doom configuration
is involved. See [installation](installation.md#reproduce-the-installation-checks)
for commands and the tested scope. CI adds plain startup to the existing core
matrix and requires Linux Emacs 31.1 installation jobs for plain adapters and Doom.

## MELPA archive preparation — 2026-10-06

`scripts/check-package --all-transports` built the recipe with pinned upstream
package-build, installed its tarball through `package-install-file`, and passed
126 regression tests on macOS Emacs 31.1 using the installed bytecode and scripts.
The isolated source snapshot was deleted before installation. The archive holds
18 production Lisp libraries, the generated package descriptor and three runtime
scripts; fresh-process checks verified generated autoloads and optional loading.
An additional archive run on Emacs 30.1 passed its 85 core regression tests.
The checkout core check passed 89 tests and compiled all 18 libraries.

The compiled archive also booted and restarted in the disposable Doom 2.2.4
installation from the installation checks above, with sidebar Evil navigation,
leader bindings and saved fixture identity verified. This reused that isolated
Doom dependency installation; it did not change the maintainer's configuration.

Package-lint 0.26 at `1865be780a16098f972fef50a52b21ca6ee04df9` reports only
[seven documented delayed-integration warnings](../packaging/README.md#documented-package-lint-exceptions).
Checkdoc passes with spelling and the experimental verb heuristic disabled;
byte-compilation treats warnings as errors. The required archive CI job covers
Linux Emacs 29.1 and 31.1, including all optional transports.

These are local snapshot builds, not an upstream MELPA submission or a stable
release. Public-maintenance duration, human review and the final upstream recipe
build remain on the [submission checklist](../packaging/README.md#before-submitting).
