# M-x Machina backlog: from prototype to daily use

Created 2026-10-01. Checked items are implemented; unchecked items are planned.
Priorities describe sequence, not promised dates. The current
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

- [x] **REC-1 — Diagnostic view.** Show the selected interface/profile, executable
  and dependency availability, recorded and actual worktree/branch, process
  state, saved conversation ID, latest failure, and hook-bridge health. Provide
  a copyable diagnostic summary that omits credentials and conversation text.
  **Done when:** missing executable/profile, missing worktree, changed branch,
  process exit and missing SessionStart each have a distinguishable explanation;
  opening diagnostics never launches a process or changes records.
  **Completed 2026-10-01:** `i` opens local checks; `g` refreshes, `w` copies the
  summary, and `q` returns. Raw error detail stays outside the copied summary.
  Git inspection runs read-only commands; no agent is launched. See
  [validation](validation.md) for read-only, failure-path and Evil checks.
- [x] **REC-2 — Worktree and branch recovery.** Offer an explicit way to associate
  a stopped agent with a relocated worktree or accept its current branch. Show
  the old/new association and validate the chosen Git checkout before saving.
  **Done when:** cancellation changes nothing, live agents must be stopped first,
  and conversation/account identity is retained; no automatic checkout/reset or
  worktree recreation occurs. Depends on REC-1.
  **Completed 2026-10-01:** `W` chooses a checkout and confirms recorded/proposed
  path and branch. Confirmation is revalidated before saving. Existing shell
  drafts survive relocation; backend resume retains the original identity even
  when history cannot be loaded from the new directory.
- [x] **REC-3 — Profile and resume recovery.** Explain unavailable profiles,
  authentication failures, unsupported resume and missing backend history.
  Support correcting an equivalent profile only where its account and backend
  identity can be verified; otherwise guide the user through configuration repair
  or explicitly creating another agent.
  **Done when:** retry targets the original conversation and never silently
  starts a replacement; supported recovery actions have failure-path tests.
  Depends on REC-1.
  **Completed 2026-10-04:** diagnostics provides configuration/account/history
  repair guidance, and `R` confirms an exact-ID retry. Unsupported ACP resume is
  distinguished from a rejected resume; replacement remains blocked. Existing
  records have no verifiable account snapshot, so this slice uses the guided
  configuration-repair path and does not offer profile reassignment. Verified
  substitution would require additional durable identity evidence.
- [ ] **REC-4 — Real restart pilot.** Exercise real Claude sessions across a full
  Emacs shutdown/restart, including account isolation and each supported interface.
  Coordinate an interruption window with the user before stopping active work.
  **Done when:** recorded results establish resume behavior, no automatic prompt
  replay, correct unread behavior and useful failure messages. Record CLI/package
  versions and any interface-specific limits. Depends on REC-1 through REC-3.

**Next recovery milestone:** REC-4, the real restart pilot, with an agreed
interruption window. REC-1 through REC-3 are complete.

## 2. Attention and navigation

Goal: make several concurrent agents manageable without inspecting each one.

- [x] **ATT-1 — Jump to attention.** Next/previous commands for waiting agents and
  unread agents, with waiting-for-input taking priority when combining them.
  **Done when:** navigation is deterministic, collapsed ancestors reveal the
  target, archived agents are excluded, and merely navigating neither launches
  an agent nor acknowledges unread output.
  **Completed 2026-10-04:** `]` / `[` cycle a waiting-first queue in the sidebar,
  dashboard and board, with separate waiting-only and unread-only commands.
  Creation order breaks ties, navigation wraps, sidebar ancestors reveal the
  target, and the board respects its folder scope. From other buffers the Doom
  leader commands select the sidebar without replacing the conversation.
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
- [x] **UX-1 — Discoverable controls.** Add contextual key help, useful empty
  states, and consistent navigation/focus/close commands across interfaces.
  **Done when:** a new user can create, inspect, resume, archive and restore an
  agent without consulting source code; plain Emacs and Evil both work.
  **Completed 2026-10-04:** `?` opens a contextual action pane from agent views;
  `C-c ?` works in conversations, and Doom has `SPC o a ?`. Agent, folder and
  empty contexts show available actions and explain disabled ones. Targets stay
  pinned across refreshes, execution rechecks state, destructive prompts remain,
  and `q` returns to the original view. Six menu tests pass in plain Emacs and
  Evil, with terminal shortcut and layout checks.
- [ ] **UX-2 — Change a stopped agent's terminal.** Investigate EAT ↔ vterm
  switching while retaining the same Claude account and UUID. Treat agent-shell
  as a separate compatibility question, not an interchangeable terminal.
  **Done when:** supported switches preserve identity and resume behavior;
  unsupported switches explain why and leave the record unchanged. Depends on
  REC-3. Do not switch a running transport in place.

- [x] **UX-3 — Visual polish and optional agent board.** Improve sidebar
  spacing, status emphasis, selection and readable names first. Explore an
  optional full overview with agent cards, a folder/project scope and columns for
  working, waiting for input, ready and stopped. Keep the persistent sidebar as
  the everyday navigation view. Folder breadcrumbs should handle deep nesting;
  unread markers remain independent of process status.
  **Evaluate with a small prototype:** opening a card fills the conversation pane,
  keyboard navigation and narrow frames remain usable, and returning restores
  the board selection. Status comes from agents; moving a card must not pretend
  to change a running process's state. Decide whether the board adds value before
  replacing or expanding the current interface. Proposed 2026-10-04.
  **Accepted 2026-10-04:** `B` / `SPC o a b` opens cards grouped by full
  folder path and observed state; `f` scopes folders. Adaptive columns, wrapped
  names, stable selection, unread markers and conversation/board/editor return
  paths are implemented. The sidebar has lighter detail text and clearer folder
  spacing/headings. The user tested and accepted the design; further refinements
  can follow daily-use feedback.

## 4. Release readiness

This work can proceed alongside recovery; it gates a stable release.

- [x] **REL-1 — Reproducible test entry point and CI.** Provide one documented
  command for the complete suite and automated checks on the declared minimum
  Emacs version and a current version. Cover macOS/Linux where practical and
  explicitly report skipped optional terminal tests.
  **Done when:** a clean checkout can run registry, ACP, EAT, vterm and transcript
  checks without a commercial model or personal configuration; byte compilation
  treats package warnings as errors.
  **Completed 2026-10-04:** `scripts/check` provides isolated compilation/core/full
  runs with explicit optional-suite skips, pinned dependency downloads and a
  separate native vterm build. [The hosted matrix passed](https://github.com/eliraz-refael/m-x-machina/actions/runs/37234024596):
  88 core tests on Linux 29.1/30.2/31.1 and macOS 31.1, plus all 128 tests on Linux
  29.1/31.1. All 17 Lisp files compile with warnings as errors. `main` requires the
  complete matrix through the `Required checks` gate, including for maintainers.
- [x] **REL-2 — Installation and dependency compatibility.** Test a clean plain
  Emacs setup and Doom setup; document native vterm installation and supported
  dependency versions. Check newer agent-shell/Claude versions deliberately.
  **Done when:** setup does not depend on local build paths or account-specific
  configuration, and missing optional packages yield actionable messages.
  **Completed 2026-10-06:** `scripts/check-install` boots and restarts a real
  interactive plain Emacs or freshly installed Doom in a disposable home.
  Checks cover the sidebar/board, saved fixture identity, missing-package
  guidance, Doom Evil/leader bindings, pinned ACP/EAT dependencies and native
  vterm compilation/loading. The [installation guide](installation.md) and
  optional pinned Doom package bundle document the tested baseline. CI requires
  these checks. Real Claude/provider compatibility and future dependency updates
  remain explicit pilots; this does not complete REC-4 or MSG-2.
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
  **Naming chosen 2026-10-04:** M-x Machina, repository slug `m-x-machina`,
  CLI `mxm` and public Emacs entry point `mx-machina`. Lisp symbols and libraries
  now consistently use `mx-machina`; persistent storage paths and the CLI protocol
  remain unchanged. The public source repository is published with
  protected PR-only `main`; a tagged release remains pending.
  **MELPA preparation 2026-10-06:** the [recipe and archive checks](../packaging/README.md)
  cover flattened installation, bundled scripts, optional Doom bindings and
  installed transport regressions. Submission remains pending a month of public
  maintenance, thorough human review and a final build from public upstream.

## 5. Explicit agent collaboration

- [x] **MSG-1 — CLI request/reply.** Opt-in local CLI discovery, queued messages,
  correlated replies, polling/waiting and queued cancellation. Address agents by
  ID or full folder/name; preserve drafts, permission prompts and unread state.
  **Completed 2026-10-04:** agent-shell, EAT and vterm pass offline round trips;
  two fixture agents consult each other through the real CLI. Idempotent request
  IDs, pending-cycle detection, interrupted-request recovery without replay,
  bounded content, private storage and retention are implemented. Existing
  processes can use the CLI explicitly; new processes inherit discovery variables.
- [ ] **MSG-2 — Real-provider messaging pilot.** Verify Claude EAT/vterm and a
  real ACP provider with multi-turn work, long replies, human input and permission
  requests. Evaluate whether conservative visible-pane/draft holds need clearer UI.
  Autonomous task planning and dispatch remain outside this messaging feature.

## 6. Optional larger projects — decide separately

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
- **Agent orchestration:** automatic task planning/dispatch remains a separate
  product decision. MSG-1 routes explicit requests without choosing work for agents.

## Working practice

Implement each ID as a reviewable change with its acceptance checks. Update this
file as work lands; keep evidence in `validation.md`. Use isolated fixtures for
automated checks and preserve live user agents during development. Reassess the
order after the recovery pilot using actual daily-use feedback.
