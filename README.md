# M-x Machina

[![Checks](https://github.com/eliraz-refael/m-x-machina/actions/workflows/check.yml/badge.svg)](https://github.com/eliraz-refael/m-x-machina/actions/workflows/check.yml)

Persistent coding-agent sessions for Emacs: a dashboard, a worktree, and the same
conversation after restarting your editor. Built for the Emacs community, with
optional Evil and Doom bindings.

**Status: experimental v0.1.** A standalone Emacs package with a local CLI,
`mxm`, for agent discovery and messaging.

See the [prioritized backlog](docs/backlog.md) for the path from this checkpoint
to dependable daily use, starting with recovery and diagnostics.

## What you can try

- Create named sessions in existing local Git checkouts, or create a new worktree for an agent.
- Reuse your configured [agent-shell](https://github.com/xenodium/agent-shell)
  profiles, including separate account profiles.
- Run Claude Code's terminal UI in EAT or vterm, with per-account profiles and hook-based status.
- Open an interactive agent buffer from the dashboard.
- Persist the backend conversation ID, profile, worktree, branch, and launch
  history in SQLite.
- Stop an agent, restart Emacs, and explicitly resume the saved conversation.
- Jump to Dired or Magit for a session's worktree.
- Open a reusable eshell for each agent's worktree.
- Keep a session sidebar and the selected conversation visible while editing.
- Expand session details, or focus a conversation and restore the previous layout.
- See live state counts in the modeline, including while focused.
- Organize named agents in persistent, arbitrarily nested logical folders.
- Distinguish working, ready, and approval states by color, with an optional spinner.
- Keep an unread marker for new assistant output until you view or acknowledge it.
- Archive, restore or delete agent records while retaining conversation files and worktrees.
- Exercise the workflow using the included offline demo.

Adapters support agent-shell's native Emacs UI through ACP, and Claude Code's
terminal UI through EAT or vterm plus Claude hooks. Detached execution and PR/CI
integration are future work. Optional CLI messaging routes explicit requests between
agents; the manager does not decide which tasks to assign.

## Requirements

- Emacs 29.1+ built with SQLite (`M-: (sqlite-available-p)`).
- For ACP profiles: the tested dependency set is agent-shell 0.83.4, ACP 0.15.2
  and shell-maker 0.97.5. Exact test revisions are in
  [test/dependencies.json](test/dependencies.json). The adapter uses agent-shell's
  internal state; other versions need compatibility testing.
- For terminal profiles: EAT or vterm (with its native module), an authenticated
  Claude Code CLI, and Python 3.
  The hook integration targets the installed Claude Code 2.1.278 interface on macOS/Linux.
- Git. The worktree must have at least one commit.
- A configured, authenticated backend for real sessions.
- Python 3 also runs the offline demos and transport tests.
- Magit and Evil are optional.

## Load the package

Clone the repository:

```sh
git clone https://github.com/eliraz-refael/m-x-machina.git
```

For ordinary Emacs, evaluate:

```elisp
(add-to-list 'load-path "/path/to/m-x-machina/lisp")
(require 'mxm)
```

For Doom, load the example instead (adjust its location):

```elisp
(load! "m-x-machina/examples/doom.el")
```

The example sets `SPC o a a` for the sidebar, `SPC o a n` for a new session,
`SPC o a d` for the full dashboard, and `SPC o a z` to focus/restore.
It installs Evil motion-state bindings for both overview views. Existing account
profiles remain available.

You can evaluate the example temporarily using `M-x load-file`; adding it to
your configuration makes it available after restart. If your Doom configuration
is literate, put the load form in its source Org file.

## Commands and compatibility

Use `M-x mxm` to open the sidebar, `M-x mxm-new` to create an agent,
`M-x mxm-board` for the board, and `M-x mxm-dashboard` for the session table.
`M-x mxm-messaging-mode` enables the local CLI message service.

The project name is **M-x Machina**, the repository slug is
`m-x-machina`, and the CLI is `mxm`. Add the checkout's `scripts/` directory to
PATH to invoke `mxm` directly, or use its full path. No global installation is
performed by loading the package.

Existing checkouts can keep their `emacs-agents` directory name. Existing
`emacs-agents-*` commands, settings, Doom bindings, registry location and
`EMACS_AGENTS_*` environment variables continue to work. `scripts/emacs-agents`
is a compatibility launcher for `mxm`; both reach the same message service.
No saved agents or conversation IDs need migration. The configuration examples
below retain the established customization variable names.

## Offline demo

Load `examples/demo.el` using `M-x load-file`, then run `M-x emacs-agents-demo`.
This creates a small demo Git repository under your registry directory and opens
a local fake agent. No model, credentials, or network connection is used.

1. Send a message using `M-x agent-shell-submit`. The reply shows a conversation
   ID and turn counter.
2. Run `M-x emacs-agents`. Press `i` to inspect the saved identity, then `x` to stop.
3. Press `RET` to resume. Send another message; the counter continues.
4. Restart Emacs, load the package and demo file again, then open the dashboard.
   The session is stopped until you press `RET`; its next reply keeps the counter.

Reloading the demo file restores its profile definition; this is also required
before resuming a demo session in a new Emacs process.

Send `/work` to simulate 20 seconds of work, or `/work 60` for a minute
(1–300 seconds). The mock stays busy through the normal ACP prompt lifecycle,
so the blue status and spinner are real UI reactions to its pending response.
It returns to ready when the reply arrives. Close its view while it works to
see the unread marker afterward. `M-x agent-shell-interrupt` cancels the simulation;
`x` in the sidebar stops the mock process. No model or network call is involved.
After updating the fixture, stop and resume an already-running demo once to load
the new commands; its saved conversation ID is retained.

## Use a real agent

Run `M-x emacs-agents`, press `n`, and choose a name and Git repository/worktree.
The next prompt asks whether to create a new worktree for this agent:

- **No:** associate the agent with the selected checkout.
- **Yes:** choose a new branch and directory (suggestions use the agent's name).
  Git creates the worktree from the selected checkout's current commit; uncommitted
  changes stay in the original checkout. Existing branches/directories are rejected.

Then choose an agent-shell profile and logical folder. Cancelling the prompts
creates no worktree. The new worktree's directory and branch are saved with the
agent and shown in its conversation header. If saving fails after Git creates the
worktree, the error reports its location so you can retry using that existing checkout.
The record is created stopped. Press `RET` to launch it,
then interact through agent-shell as usual. Starting a real backend uses that
backend's account and usage allowance.

## Claude Code through EAT

Choose `claude-eat` as the profile when creating an agent to use Claude's terminal
UI. EAT and agent-shell sessions share the same sidebar, folders, worktree context,
focus/close commands, and five-second reading delay. Existing sessions retain their
original profile; create a new session to try a different backend.

For separate accounts, set profiles with distinct identifiers and explicit environments:

```elisp
(setq emacs-agents-eat-profiles
      `(((:identifier . claude-eat-work)
         (:command . ("claude"))
         (:environment . (,(concat "CLAUDE_CONFIG_DIR="
                                   (expand-file-name "~/.claude-work")))))))
```

These environments apply only to the profile's subprocess. Profile identifiers
must be unique across both adapters. Keep each profile's account and backend
stable so its saved conversations continue to resolve.

The adapter supplies per-run `--settings` hooks; it does not edit your Claude or
project settings. Hooks observe session identity, submitted prompts, tool activity,
permission/input requests, assistant message display, turn completion, and model
changes. Terminal redraws and resumed history do not create unread notifications.
The bridge writes only event metadata, never prompt/response text or tool payloads.
Claude still handles its normal permission decisions.

`C-c C-z` toggles focus, `C-c C-q` closes the view, and `C-<escape>` sends Escape
to Claude (with Evil, bare Escape leaves insert state). Type in Evil insert state;
normal-state `q` closes the conversation view. Without Evil, EAT uses semi-char mode.
The terminal remains running when its view is closed.

Creation asks for **agent → account → interface**. Choose `eat`, `vterm`, or
`agent-shell` from the interfaces configured for that account. Existing saved
profiles retain their IDs and conversation identity. Optional `:agent` and
`:account` labels group profiles in the picker; for example, add
`(:agent . "Claude") (:account . "work")` to the EAT and agent-shell account
profiles. Vterm inherits EAT commands and environments by default, with `-vterm`
appended to its profile IDs. Customize `emacs-agents-vterm-profiles` to provide
separate profiles, or set it to nil to hide vterm. Its native module must be
installed before launching a vterm agent.

**Vterm:** Page Up/Down and the wheel navigate Claude's fullscreen history;
Evil normal-state `C-u`/`C-d` do the same. `C-c C-b` returns to current output.
`C-c C-t` opens the same saved transcript as EAT. For ordinary terminal
scrollback or native selection, `C-c C-r` toggles vterm copy mode, which pauses
terminal display; `C-c C-b` returns to the live display. Vterm retains 10,000
scrollback lines. Its wheel navigation uses page steps.

**Eshell:** press `e` on an agent in the sidebar or dashboard, or run
`M-x emacs-agents-eshell`. This opens a separate shell in that agent's worktree
without starting or stopping the agent. Reopening it preserves its current
directory, command history and unsent input. Different agents get separate
shells, even when they share a worktree. Eshell is a companion for commands;
the agent conversation stays in the selected interface.

**EAT:** scroll with the **mouse wheel** or **Page Up / Page Down** (Mac: **Fn-Up / Fn-Down**).
With Evil, **C-u / C-d** also scroll in normal state. In Claude's fullscreen
renderer these commands reach Claude's own history, so older messages remain
accessible while Claude streams. In the classic renderer they scroll the Emacs
buffer. **C-c C-b** returns to the latest output; **C-Home** goes to the beginning.
The terminal mode line says `History:C-c C-b` while browsing fullscreen history.
Use `C-c C-b` to resume automatic read acknowledgment: a visible prompt alone
cannot tell us whether Claude is displaying its latest message. Ordinary EAT
scrollback retains 8 MiB of characters per agent by default; customize
`emacs-agents-eat-scrollback-size` for a different limit (`nil` means unlimited).
Claude's alternate-screen history is managed by Claude and does not use that limit.

Evil normal/visual states use EAT's Emacs navigation mode; insert state returns to
terminal input at the prompt. For stable selection across long replies, press
`C-c C-t` in the terminal to open the saved conversation as ordinary text. Use
`V`, motions and `y` to copy lines; `g` refreshes the snapshot and `q` returns to
the terminal. This view includes user and assistant text, excluding tool payloads.
It stays still while the agent works and does not automatically mark new output read.
New assistant output marks its header **stale — g to refresh**. Internal command
and task-notification envelopes are omitted from the conversation text.

A new session receives a UUID; `SessionStart` confirms it before the sidebar
reports ready. Resume passes that exact ID to `claude --resume`. Switching to a
different conversation with `/clear`, `/fork` or `/resume` causes the adapter to
stop when its hooks report the changed ID, preserving the saved association.
Create another managed agent when you want another conversation. A missing saved
conversation fails instead of deliberately launching a replacement.

If onboarding, workspace trust, or disabled hooks prevent `SessionStart`, the
sidebar stays starting/unknown and `i` explains what to check. Claude has no Stop
hook for user interruption: `C-<escape>` reports unknown until a subsequent hook
confirms activity. Plain text questions count as unread replies; structured input
and permission requests show the waiting state. This prototype uses Emacs-owned
processes; it does not keep agents running through an Emacs restart.

## Persistent overview and focus

`M-x emacs-agents` opens a dedicated sidebar. A compact colored dot (or working
spinner) shows state beside the agent's name; TAB and hover show the full status.
Collapsed agents occupy one row. A subtle background marks the conversation displayed in the main
pane independently of the sidebar navigation cursor. `TAB` expands the agent's
own status, directory, branch, profile and saved-ID status without starting it.
Hovering shows the complete name, folder, status and directory. Long rows are
truncated rather than wrapped; deep indentation is capped with an ellipsis to
reserve room for names. Logical folder nesting remains unlimited.
`D` opens the full table in the editing area.

Status colors use customizable Emacs faces: blue for working, green for ready,
amber for confirmed input/approval requests, red for errors, and muted text for
stopped/unknown. A small spinner runs beside working agents; set
`emacs-agents-animate` to nil to disable it. Text labels remain available under TAB
and in conversation headers. The current line is highlighted for keyboard navigation.

Purple `*` and the agent name indicate unseen assistant output independently
of activity. A ready agent may still have an unread reply. The marker is saved
in SQLite and survives restart. It clears after **5 continuous seconds** with the
conversation selected in an active frame and its latest output visible. Switching
agents, scrolling away, losing focus, or receiving new output restarts the countdown;
brief visits do not add up. Customize `emacs-agents-read-delay` to use another
delay, such as 3 seconds (0 restores immediate acknowledgment). Press `u` to mark
an agent read immediately. Merely showing its buffer in an unselected window
does not acknowledge it. Replayed history and thought/tool events do not
create unread markers. This is one unread flag per agent, not a message count.

The adapter identifies working, ready and permission requests from structured
events. An ordinary question embedded in reply text is marked unread; it is not
automatically classified as a confirmed input request. Future adapters can report
an explicit waiting state. The UI does not guess intent from punctuation.

## Names and folders

Folders organize sessions; they do not move worktrees or correspond to filesystem
directories. For example, create `Work/Wix Panels` and put agents named `Harness`
and `Migrating to Effect v4` inside it. There is no package-imposed nesting limit.

- `N`: create a folder and any missing parents, using `/` between levels.
- `n`: create a named agent; the folder prompt defaults to the selected folder.
- `M`: move an agent to a folder (blank means the root).
- `R`: rename the agent without changing its provider conversation ID.
- `TAB` or `RET` on a folder: collapse/expand it without launching agents.

Folder rows summarize working/waiting agents and unread replies in their entire
subtree, even while collapsed. Empty folders persist. Folder paths and agent
names are stored separately from backend profiles and reported model names.
Folder deletion/renaming is not yet exposed; agents can be moved freely.

Two native header rows above the conversation show the agent name, colored
activity, Git project name, last reported model, worktree path, recorded branch,
and logical folder. Long rows may be clipped by narrow windows; hover for the full
text or press `i` in the sidebar to inspect the session. Unknown models are labeled
`not reported`; the UI never infers the model from a profile's name.

`RET` opens or resumes the selected agent in the entire editing area beside the
sidebar, consolidating any ordinary editor splits. Opening another agent reuses
that area and retains the previous conversation buffer and draft. The sidebar
stays visible during normal file navigation and `delete-other-windows`.
`f` and `m` use the editing area for Dired and Magit.
Use `q` in the sidebar to hide it deliberately; this does not stop agents.

Close the conversation view with `C-c C-q`, `q` in Evil normal state, `c` in the
sidebar, or `SPC o a c` in Doom. This restores the editor layout saved before the
first `RET`, leaving the sidebar visible. Switching agents does not overwrite
that layout. Closing keeps the agent running and preserves its buffer and draft;
use `x` to stop the process explicitly. Closing from focus exits both views.

Press `z` in either overview, `C-c C-z` in a managed conversation, or use
`M-x emacs-agents-focus` to fill the frame with that conversation. Toggle again
to restore the previous windows, sizes and selection. Sending a prompt does not
exit focus. Opening the sidebar also restores the layout. Focus is tracked per
frame; the saved layout is temporary and does not survive restarting Emacs.
If a saved buffer is killed while focused, Emacs restores a surviving buffer in
its place. Custom workspace/window managers can still replace frame layouts.

The overview enables `emacs-agents-status-mode`, which adds cached counts to
`global-mode-string` (also shown by Doom modeline's `misc-info` segment):

```text
Agents: 3 working · 2 ready · 1 approval · 4 stopped
```

`ready` means idle and accepting a prompt; `approval` means a backend permission
request. These states do not establish task completion or detect arbitrary
questions in transcript text. Starting, unknown and error counts appear when
present; zero counts are omitted. Refreshes preserve selection and never move
keyboard focus. Rendering the modeline does not query SQLite or launch agents.
Disable just the counts with `M-x emacs-agents-status-mode`.

Customize `emacs-agents-sidebar-side` (left/right) and
`emacs-agents-sidebar-width` (columns). The sidebar uses side-window slot 1 to coexist with a sidebar
in slot 0, such as Treemacs. Narrow frames may need smaller pane sizes.

| Key | Action |
| --- | --- |
| `?` | Contextual action menu with availability explanations |
| `n` | Create a session |
| `N` | Create a logical folder |
| `M` | Move the agent to a folder |
| `R` | Rename the agent |
| `u` | Acknowledge unread output |
| `RET` / `r` | Open, start, or resume the selected session |
| `x` | Stop its process and retain the session |
| `i` | Diagnose the selected agent without starting it |
| `W` | Review and change a stopped agent's worktree/branch association |
| `TAB` | Expand/collapse sidebar details |
| `D` | Open the expanded dashboard (sidebar) |
| `B` | Open the optional agent board |
| `]` / `[` | Next / previous agent needing attention |
| `s` | Return to the sidebar (dashboard) |
| `z` | Focus conversation / restore layout |
| `c` | Close the conversation view (sidebar) |
| `f` | Open its worktree in Dired |
| `m` | Open Magit |
| `g` | Refresh |
| `q` | Close the dashboard window |
| `j` / `k` | Navigate sessions (sidebar; optional Evil setup for the table) |

The dashboard distinguishes process state from activity. `input` means the agent
is ready for input, not that your task is complete. `pending` identity means no
backend conversation ID has been captured yet.

### Agent board

Press `B` in the sidebar/dashboard, `SPC o a b` with the Doom example, or run
`M-x emacs-agents-board`. The board uses the main pane beside the sidebar. Cards
are grouped by their full folder path, with Working, Waiting, Ready and Stopped
columns. Approval requests are Waiting; errors appear in Stopped with an explicit
ERROR label. Starting/unknown agents appear in an additional Other lane.

`f` scopes the view to a folder and its descendants; choose All folders to clear
it. Names wrap inside cards, unread output has a separate NEW marker, and narrow
windows stack columns. Navigate with `h/j/k/l`, arrows or `TAB`; `RET` or a click
opens the conversation without another split. Closing that conversation restores
the board and selected card. `i` opens diagnostics, `g` refreshes, `n` creates an
agent, and `q` restores the layout from before the board. Merely navigating cards
does not launch agents or acknowledge unread output.

The board reflects actual agent states; cards cannot be dragged into a different
status. It is an optional prototype for comparing the overview with the sidebar,
not a replacement for the compact view. Sidebar folder headings now have clearer
weight and separation, details are muted, and unread names retain emphasis.
Customize `emacs-agents-sidebar-line-spacing` (default `0.12`, `0` for compact)
to adjust its vertical density.

### Attention navigation

Use `]` / `[` in the sidebar, dashboard or board to cycle through agents that
need attention. The queue puts input/approval requests first, then agents with
unread output. Each group keeps creation order; an agent in both groups appears
once. Navigation wraps, and when the current agent is outside the queue, either
direction starts at its highest-priority entry. Idle/ready agents only qualify
when unread; archived agents are excluded.

Sidebar navigation expands only the target's ancestor folders. Board navigation
respects its current folder scope (`f` changes scope). Neither starts an agent
nor marks messages read; `RET` opens the selected conversation. The minibuffer
shows the queue position and reason for attention. If nothing qualifies, your
selection stays in place. Resolved requests leave the queue on the next command.

With the Doom example, `SPC o a ]` / `SPC o a [` work from any buffer and select
the sidebar entry when invoked outside an overview. For a narrower queue, use
`M-x emacs-agents-next-waiting` / `emacs-agents-previous-waiting` or
`emacs-agents-next-unread` / `emacs-agents-previous-unread`.

### Contextual actions

Press `?` in the sidebar, dashboard, board or diagnostics, `C-c ?` inside a
managed conversation, or `SPC o a ?` with the Doom example. A temporary bottom
pane lists actions for the selected agent, with explanations beside disabled
choices. On a folder or in an empty view, creation and navigation remain
available without selecting an agent.

Use the displayed letter, move with arrows or `j/k` and press `RET`, or click
an enabled action. These are menu-local keys: `o` opens, `r` retries saved history,
`R` renames, `a` archives and `s` restores. `g` refreshes availability; `q` or `?`
closes the menu and returns to the originating view. A running agent's archive
entry says “Stop and archive” and retains its confirmation prompt.

The menu retains the original target if rows move, and rechecks its state before
executing an action. Opening it neither starts an agent nor acknowledges unread
output. It uses ordinary Emacs buffers and works with the optional Evil setup.

## Agent-to-agent CLI messaging (experimental)

Enable `M-x mxm-messaging-mode` in the owning Emacs, or add:

```elisp
(require 'mxm)
(mxm-messaging-mode 1)
```

This starts a local Emacs server if needed. Python 3 and `emacsclient` must be on
PATH. The first version uses a local Unix socket and the same OS user's trust
boundary as `emacsclient`; sender IDs are attribution, not an authentication
boundary between agents. It supports agent-shell, EAT and vterm.

From a terminal (adjust the checkout path):

```sh
/path/to/m-x-machina/scripts/mxm list
/path/to/m-x-machina/scripts/mxm send 'Work/Wix Panels/Harness' 'Please review the API changes and summarize your findings.' --wait
/path/to/m-x-machina/scripts/mxm result REQUEST_ID
/path/to/m-x-machina/scripts/mxm wait REQUEST_ID --timeout 120
/path/to/m-x-machina/scripts/mxm cancel REQUEST_ID
```

Use an exact agent ID or a unique full folder/name. `list` and all request results
are JSON. `send` without `--wait` returns a request ID immediately; `--wait`
returns the completed text reply to that specific message, not a terminal-screen
snapshot. Use `-` as the message to read stdin. A wait timeout exits with code 2
and leaves the request active; failures exit with code 1. Check the printed ID
before retrying an interrupted CLI call. `--request-id` reuses a retained request
without sending it twice, and rejects reuse for different content.

Agents started while messaging is enabled inherit `EMACS_AGENTS_ID`,
`EMACS_AGENTS_CLI` and `EMACS_AGENTS_SOCKET`. Give them this instruction:

> First run `"$EMACS_AGENTS_CLI" whoami` to see your registered ID, full name
> and working directory. To consult another agent, run `"$EMACS_AGENTS_CLI" list`, then
> `"$EMACS_AGENTS_CLI" send TARGET_ID "your question" --wait`. Your sender ID is
> supplied automatically. The JSON response contains the peer's reply. If waiting
> times out, use `result` or `wait` with the existing request ID; do not resend.

Already-running agents can use the full CLI path for `whoami` and `send`.
When the ID environment variable is absent, the manager traces the CLI's process
ancestors to its live managed agent. Identity never depends on matching a working
directory or guessing a name. No restart or manual `--from` is needed. Supply
`--socket /path/to/emacs/socket` before the subcommand for a nondefault server.
Outside a managed process, `whoami` reports that no identity was found; `send`
uses the user CLI identity unless you explicitly supply `--from SENDER_ID`.

Delivery waits while the recipient is busy, awaiting approval, visible in any
Emacs window, or holding an unsent draft. Hide its conversation to allow delivery.
Existing terminal buffers initially have uncertain draft state: submit your draft
normally, or clear the terminal's prompt and run
`M-x emacs-agents-messaging-ready` for that agent. This command confirms the prompt
is empty; it does not erase anything. Terminal navigation can conservatively hold
further delivery too. Agent-shell checks its actual input buffer. Sending never
launches stopped agents, answers permission prompts, switches your visible view,
or acknowledges unread output.

Each recipient processes one queued request at a time. A matching prompt
acknowledgment is required before collecting its response. agent-shell replies use
streamed text through turn completion; Claude terminal replies use the Stop hook's
last assistant message. Tool output is not included. Interrupted turns, identity
changes, missing acknowledgment, or missing reply text fail explicitly. Pending
request cycles, including self-messages, are rejected when sender IDs are supplied.

`cancel` affects only queued requests. Once submitted, use the conversation's
normal interrupt control. Requests expire after 30 minutes; disabling messaging,
manager shutdown or recovery after a crash ends pending requests without replay.
The agent may still have performed work after an uncertain delivery: inspect its
conversation before issuing a new request. Messages are limited to 16 KiB and
captured replies to 128 KiB.

Requests and replies are stored as private JSON files under the registry's
`messages/` directory (directory mode 0700, files 0600), separate from backend
history. Completed records and their idempotency keys expire after seven days
while messaging runs; customize `emacs-agents-messaging-retention-days` (minimum
one day). A storage failure disables messaging without stopping healthy agents.
This has offline integration coverage for all three interfaces; real Claude
messaging still needs an interactive pilot before stable-release claims.

## Lifecycle and recovery

The session ID identifies the managed record. The conversation ID identifies the
backend conversation. Each launch gets a new run ID; reopening a live buffer does
not launch another process.

Press `i` in the sidebar or dashboard, or run `M-x emacs-agents-diagnostics`,
to inspect an agent. Diagnostics fills the main pane; `g` refreshes the snapshot,
`w` copies its summary, and `q` returns to the previous buffer. These keys also
work with the optional Evil setup. Inspecting an agent leaves its unread flag
and saved records unchanged, including when the manager has not opened its
registry yet.

Checks distinguish a missing profile or executable, unavailable dependencies,
a missing checkout or changed branch, an exited process, and unconfirmed Claude
SessionStart. Terminal checks show the event poller and event-file availability;
they do not consume events. Authentication and backend history are not contacted.
Dependency presence does not establish version compatibility or successful login.
For agent-shell profiles, diagnostics uses a tracked process's executable when
available. Otherwise, optionally add `(:diagnostic-command . "executable-name")`
to the profile alist; client factories are never invoked to discover a command.

The copied summary includes local paths, agent metadata and full IDs, but excludes
command arguments, environment values, conversation contents and raw failure text.
The latest raw failure appears separately in the local view and is omitted by
`w`; copying the entire buffer manually also copies that failure detail.

Press `W` in the sidebar, dashboard or diagnostics, or run
`M-x emacs-agents-rebind-worktree`, to recover a stopped agent's checkout
association. Choose the relocated worktree, or keep the current directory to
accept its actual branch. Review the recorded and proposed path/branch, then
confirm. Cancelling leaves the registry untouched. The command checks again
after confirmation and refuses if the record or checkout changed meanwhile.
Stop running agents with `x` first and wait for their process to exit.

Recovery saves the path, branch and project while retaining the agent's profile,
conversation ID, folder, unread flag and run history. It does not move files,
create worktrees, switch branches or start an agent. Existing eshell buffers keep
their jobs and drafts; after a path change, `e` opens a new associated shell in
the chosen checkout. Open the agent explicitly when ready to resume.

Backend history can depend on the old working directory. A valid new association
does not guarantee the provider can load that conversation there. Resume still
requests the original ID; a refusal never silently creates another conversation.
Backend history relocation is not automated. Profile/account guidance follows.

Diagnostics now includes recovery steps for missing profiles, authentication
failures, unsupported resume, missing history and unconfirmed terminal startup.
After repairing the original configuration, press `R` **inside diagnostics**
(`M-x emacs-agents-retry` elsewhere). Review the profile and saved conversation ID,
then confirm the retry. `R` still renames agents in the sidebar. Retry requires a
stopped, active record with a saved conversation and a valid checkout. It checks
for configuration/record changes during confirmation and submits no prompt.

The registry has no verified record of the original provider account. Recovery
therefore guides restoration of the original profile identifier and account;
it does not substitute another profile based on its label or displayed model.
For terminal profiles, retain the original `CLAUDE_CONFIG_DIR` and authentication
configuration. For ACP profiles, restore the original agent-shell configuration.
If the backend cannot resume or the history is gone, explicitly create a separate
agent with `n`; retain the old record while investigating. Terminal startup without
SessionStart cannot by itself distinguish login, trust, hooks and missing history.

The implementation stops managed ACP transports when the Emacs process exits
normally. Closing a client frame while an Emacs daemon stays alive does not stop
them. Killing a live managed agent buffer is blocked: bury it to hide it or use
`emacs-agents-stop` first. Use the dashboard for starting and resuming managed
sessions instead of the backend's own restart/fork commands.

After restart, opening the dashboard loads metadata only. Press `RET` to resume
the same conversation, with the same profile and worktree. Input is never
automatically replayed: it may already have performed work before a disconnect.

The adapter allows read-only session listing, including agent-shell's automatic
title refresh. It blocks fallback requests to create or select a different
conversation when restoration fails. The session retains its original ID and
shows the failure under `i`. Fix the backend/profile/history issue and retry. If
initialization ended before an ID was captured, automatic retry is blocked;
inspect the old buffer or deliberately create a new managed session. A provider
can also issue an ID before it has saved any conversation history. If it later
reports `Resource not found` for that ID, retain the failed record and explicitly
create a fresh agent; the manager does not silently replace its identity.

Changed branches and missing worktrees block launch rather than causing a reset
or checkout. Restore the recorded worktree/branch first. The prototype does not
delete branches, worktrees, or backend conversation files.

### Archive, restore and delete

- `a` in the sidebar or dashboard archives an agent. If it is running, a prompt
  offers to stop and archive it; cancelling leaves it running. Archived agents
  disappear from the active sidebar and status counts, but keep their folder,
  conversation identity, unread state, profile and worktree.
- `A` opens **Archived Agents**. `RET` or `r` restores the selected record without
  launching it. Open it from the sidebar to resume its saved conversation.
  `A` in the archive returns to the active dashboard.
- `d` deletes the selected record, including its local run records, after a
  confirmation. For a running agent the same confirmation explicitly includes
  stopping its process. Conversation files, branches and worktrees remain on
  disk; open conversation buffers and eshell drafts are retained.

These commands also exist as `M-x emacs-agents-archive`, `emacs-agents-archived`,
`emacs-agents-restore`, and `emacs-agents-delete`. The registry upgrades to schema
3 automatically. Restoring and deleting do not require the worktree to exist.

An external host for optional background execution is planned. Full descendant
process cleanup after an abrupt Emacs crash is not guaranteed by this adapter.
Stop requests interrupt and shut down ACP, or terminate the managed EAT process; cleanup
of backend-spawned processes also depends on the backend. Reconcile any surviving
backend processes before resuming after a crash.

## Storage

Schema v2 migrates existing v1 registries transactionally, preserving session,
conversation and run IDs. Existing agents initially appear at the root. Migration
can also run against an already-open registry without resetting live processes.

`emacs-agents-directory` defaults to `emacs-agents/` under `user-emacs-directory`.
Set it before opening the registry. Keep it on a local filesystem. One Emacs
instance owns a registry at a time.

The SQLite database contains identifiers, paths, profile names, lifecycle state,
and diagnostics. Conversation history and credentials remain with the backend;
agent-shell also manages its own transcripts. Back up the registry together with
the backend's conversation storage. Keep profile definitions stable across
restarts; the package stores their identifiers, not credentials.

EAT keeps private `terminal-runs/run-*/` hook settings and event logs while a run
is active. Stop, process exit and failed setup remove that run's temporary files;
the terminal buffer remains available for inspection. Abandoned directories from
crashes or older versions may be removed manually; they hold no conversation history.

## Development

Run compilation and the core tests without optional packages or downloads:

```sh
python3 scripts/check
```

For the complete release check, including ACP, EAT, native vterm and the messaging
CLI, use:

```sh
python3 scripts/check --suite all --fetch-deps --build-vterm
```

This downloads exact Git revisions into `.cache/test-deps/` and builds a separate
vterm module there. It needs Git, Python 3, Emacs with SQLite and dynamic modules,
CMake, a C compiler, Make, libtool and `tic` (ncurses). After the initial setup,
`python3 scripts/check --suite all` reuses that cache without fetching dependencies.
See [the testing guide](docs/testing.md) for targeted checks and CI coverage.

Every run copies the package into a temporary directory, compiles with warnings
as errors, and tests with `emacs --batch -Q`. Registry files, Emacs state, native
compilation caches and server sockets are isolated. The runner never loads Doom,
contacts a real model, or connects to the user's Emacs server. Optional suites
are explicitly reported as skipped when not selected; selecting a suite with
missing dependencies fails instead of silently passing.

`make test` and `make check` run the core check; `make test-all` runs the complete
check. `--emacs /path/to/emacs` selects another Emacs binary. The fixtures exercise
resume, terminal status and peer messaging without commercial accounts. See
[validation](docs/validation.md) for results and remaining real-provider checks.

See [the design](docs/design.md) for the broader roadmap.

## Contributing

Ideas, bug reports, documentation, and patches are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for setup and the PR workflow. Prefer small changes
that make managing sessions more reliable and more natural in Emacs. Describe
the workflow a change enables and how its behavior can be checked.

## License

GNU General Public License, version 3 or (at your option) any later version.
See [LICENSE](LICENSE).
