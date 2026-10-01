# Backlog: from prototype to daily use

Created 2026-10-01. This is the working plan; all items below are planned, not
implemented. Priorities describe sequence, not promised dates. The current
milestone is a checkpoint, not a stable release.

## Current baseline

Implemented: persistent agents and conversation identity; EAT, vterm and
agent-shell interfaces; account selection; associated eshells; optional Git
worktree creation; nested folders and agent naming; sidebar/status counts;
focus and close-view controls; status colors, animation and delayed unread
acknowledgment; terminal scrolling and saved transcripts; archive, restore and
record deletion. See [validation](validation.md) for coverage and limitations.

The conversation is durable, but a running process does not survive closing
Emacs. Backend history and credentials remain owned by the backend. Changing
interface on an existing agent is not currently exposed.

## 1. Recovery and diagnostics — next milestone

Goal: when an agent cannot start or resume, the user can understand why and take
an explicit recovery action without losing its saved identity.

- [ ] **REC-1 — Diagnostic view.** Show the selected interface/profile, executable
  and dependency availability, recorded and actual worktree/branch, process
  state, saved conversation ID, latest failure, and hook-bridge health. Provide
  a copyable diagnostic summary that omits credentials and conversation text.
  **Done when:** missing executable/profile, missing worktree, changed branch,
  process exit and missing SessionStart each have a distinguishable explanation;
  opening diagnostics never launches a process or changes records.
- [ ] **REC-2 — Worktree and branch recovery.** Offer an explicit way to associate
  a stopped agent with a relocated worktree or accept its current branch. Show
  the old/new association and validate the chosen Git checkout before saving.
  **Done when:** cancellation changes nothing, live agents must be stopped first,
  and conversation/account identity is retained; no automatic checkout/reset or
  worktree recreation occurs. Depends on REC-1.
- [ ] **REC-3 — Profile and resume recovery.** Explain unavailable profiles,
  authentication failures, unsupported resume and missing backend history.
  Support correcting an equivalent profile only where its account and backend
  identity can be verified; otherwise guide the user through configuration repair
  or explicitly creating another agent.
  **Done when:** retry targets the original conversation and never silently
  starts a replacement; supported recovery actions have failure-path tests.
  Depends on REC-1.
- [ ] **REC-4 — Real restart pilot.** Exercise real Claude sessions across a full
  Emacs shutdown/restart, including account isolation and each supported interface.
  Coordinate an interruption window with the user before stopping active work.
  **Done when:** recorded results establish resume behavior, no automatic prompt
  replay, correct unread behavior and useful failure messages. Record CLI/package
  versions and any interface-specific limits. Depends on REC-1 through REC-3.

**First implementation slice:** REC-1 as a small diagnostic view built on the
existing details command. Then REC-2, REC-3, and the REC-4 pilot.

## 2. Attention and navigation

Goal: make several concurrent agents manageable without inspecting each one.

- [ ] **ATT-1 — Jump to attention.** Next/previous commands for waiting agents and
  unread agents, with waiting-for-input taking priority when combining them.
  **Done when:** navigation is deterministic, collapsed ancestors reveal the
  target, archived agents are excluded, and merely navigating neither launches
  an agent nor acknowledges unread output.
- [ ] **ATT-2 — Sidebar filters.** Search by name/folder/project and filter by
  status or unread state. Keep active filters visible and easy to clear.
  **Done when:** filters preserve selection sensibly across updates; overall
  counts are clearly distinguished from filtered results; hidden output remains
  unread. Depends on ATT-1's shared attention selection logic.
- [ ] **ATT-3 — Optional notifications.** Allow opt-in notifications for a new
  input request, failed process or completed turn while another buffer is active.
  **Done when:** streaming chunks and repeated redraws do not cause notification
  floods; notifications respect user preferences and preserve unread semantics.

## 3. Organization and interface polish

- [ ] **ORG-1 — Folder operations.** Rename/move folders with their descendants
  and delete empty folders. Handle collisions and moves into descendants.
  **Done when:** updates are transactional, IDs/worktrees stay unchanged, archived
  agents follow folder moves too, and deep/prefix-sibling trees remain correct.
- [ ] **ORG-2 — Persistent ordering.** Reorder agents and sibling folders, with a
  predictable default for new entries.
  **Done when:** order survives restart, filtering and collapse/expand, without
  changing the underlying agent identity.
- [ ] **UX-1 — Discoverable controls.** Add contextual key help, useful empty
  states, and consistent navigation/focus/close commands across interfaces.
  **Done when:** a new user can create, inspect, resume, archive and restore an
  agent without consulting source code; plain Emacs and Evil both work.
- [ ] **UX-2 — Change a stopped agent's terminal.** Investigate EAT ↔ vterm
  switching while retaining the same Claude account and UUID. Treat agent-shell
  as a separate compatibility question, not an interchangeable terminal.
  **Done when:** supported switches preserve identity and resume behavior;
  unsupported switches explain why and leave the record unchanged. Depends on
  REC-3. Do not switch a running transport in place.

## 4. Release readiness

This work can proceed alongside recovery; it gates a stable release.

- [ ] **REL-1 — Reproducible test entry point and CI.** Provide one documented
  command for the complete suite and automated checks on the declared minimum
  Emacs version and a current version. Cover macOS/Linux where practical and
  explicitly report skipped optional terminal tests.
  **Done when:** a clean checkout can run registry, ACP, EAT, vterm and transcript
  checks without a commercial model or personal configuration; byte compilation
  treats package warnings as errors.
- [ ] **REL-2 — Installation and dependency compatibility.** Test a clean plain
  Emacs setup and Doom setup; document native vterm installation and supported
  dependency versions. Check newer agent-shell/Claude versions deliberately.
  **Done when:** setup does not depend on local build paths or account-specific
  configuration, and missing optional packages yield actionable messages.
- [ ] **REL-3 — Persistence and upgrade checks.** Exercise upgrades from supported
  schemas, backups, registry ownership, interrupted writes and retained history.
  **Done when:** recovery is documented and verified without erasing conversation
  IDs or confusing stale process observations with active agents.
- [ ] **REL-4 — Performance and usability pilot.** Test many agents/folders, long
  transcripts, concurrent streaming, resize/focus changes and extended sessions.
  **Done when:** record the tested scale and measurements; address demonstrated
  bottlenecks and usability failures before declaring a stable version.
- [ ] **REL-5 — Release checkpoint.** Choose the package name/version, update
  installation docs and changelog, and record known limitations.
  **Done when:** recovery and release gates above are met and release/publishing
  is explicitly authorized. No publication is implied by this backlog.

## 5. Optional larger projects — decide separately

- **Detached execution:** a process host that can keep agents working while Emacs
  is closed. First design ownership, reattachment, process cleanup and failure
  handling; preserve the option to stop with Emacs. This is not required for v0.1.
- **Additional agent CLIs:** add only after verifying stable identity, resume,
  status and input-request semantics through the adapter boundary.
- **Worktree cleanup:** a separate explicit action that checks dirty files,
  shared ownership and running agents. Record deletion must continue to retain
  worktrees by default.
- **PR/CI context:** optional links and status for an agent's branch, after the
  local session lifecycle is dependable.
- **Agent orchestration:** coordination or automatic dispatch would be a separate
  product decision; the current manager does not send prompts on its own.

## Working practice

Implement each ID as a reviewable change with its acceptance checks. Update this
file as work lands; keep evidence in `validation.md`. Use isolated fixtures for
automated checks and preserve live user agents during development. Reassess the
order after the recovery pilot using actual daily-use feedback.
