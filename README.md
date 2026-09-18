# emacs-agents

Persistent coding-agent sessions for Emacs: a dashboard, a worktree, and the same
conversation after restarting your editor. Built for the Emacs community, with
optional Evil and Doom bindings.

**Status: experimental v0.1 prototype.** The name is provisional. This is a
standalone package, independent of any personal Emacs configuration.

## What you can try

- Create named sessions in existing local Git repositories or worktrees.
- Reuse your configured [agent-shell](https://github.com/xenodium/agent-shell)
  profiles, including separate account profiles.
- Open an interactive agent buffer from the dashboard.
- Persist the backend conversation ID, profile, worktree, branch, and launch
  history in SQLite.
- Stop an agent, restart Emacs, and explicitly resume the saved conversation.
- Jump to Dired or Magit for a session's worktree.
- Exercise the workflow using the included offline demo.

The first adapter uses agent-shell's native Emacs UI and structured ACP events.
EAT/vterm adapters, detached execution, creating worktrees, and PR/CI integration
are future work. The prototype does not coordinate agents or send prompts on its
own.

## Requirements

- Emacs 29.1+ built with SQLite (`M-: (sqlite-available-p)`).
- agent-shell 0.75.2+ and its dependencies. The adapter is tested against 0.75.2;
  its small compatibility boundary uses agent-shell's internal state.
- Git. The worktree must have at least one commit.
- A configured, authenticated agent-shell backend for real sessions.
- Python 3 only for the offline demo and transport tests.
- Magit and Evil are optional.

## Load the package

For ordinary Emacs, evaluate:

```elisp
(add-to-list 'load-path "/path/to/emacs-agents/lisp")
(require 'emacs-agents)
```

For Doom, load the example instead (adjust its location):

```elisp
(load! "emacs-agents/examples/doom.el")
```

The example sets `SPC o a a` for the dashboard and `SPC o a n` for a new session.
It also installs Evil motion-state bindings for the dashboard. Existing account
profiles remain available.

You can evaluate the example temporarily using `M-x load-file`; adding it to
your configuration makes it available after restart. If your Doom configuration
is literate, put the load form in its source Org file.

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

## Use a real agent

Run `M-x emacs-agents`, press `n`, choose a name, an existing worktree, and an
agent-shell profile. The record is created stopped. Press `RET` to launch it,
then interact through agent-shell as usual. Starting a real backend uses that
backend's account and usage allowance.

| Key | Action |
| --- | --- |
| `n` | Create a session |
| `RET` / `r` | Open, start, or resume the selected session |
| `x` | Stop its process and retain the session |
| `i` | Inspect full IDs and the last diagnostic |
| `f` | Open its worktree in Dired |
| `m` | Open Magit |
| `g` | Refresh |
| `q` | Close the dashboard window |
| `j` / `k` | Navigate with the optional Evil setup |

The dashboard distinguishes process state from activity. `input` means the agent
is ready for input, not that your task is complete. `pending` identity means no
backend conversation ID has been captured yet.

## Lifecycle and recovery

The session ID identifies the managed record. The conversation ID identifies the
backend conversation. Each launch gets a new run ID; reopening a live buffer does
not launch another process.

The implementation stops managed ACP transports when the Emacs process exits
normally. Closing a client frame while an Emacs daemon stays alive does not stop
them. Killing a live managed agent buffer is blocked: bury it to hide it or use
`emacs-agents-stop` first. Use the dashboard for starting and resuming managed
sessions instead of agent-shell's own restart/fork commands.

After restart, opening the dashboard loads metadata only. Press `RET` to resume
the same conversation, with the same profile and worktree. Input is never
automatically replayed: it may already have performed work before a disconnect.

The adapter blocks agent-shell's fallback requests to create or select a different
conversation when restoration fails. The session retains its original ID and
shows the failure under `i`. Fix the backend/profile/history issue and retry. If
initialization ended before an ID was captured, automatic retry is blocked;
inspect the old buffer or deliberately create a new managed session.

Changed branches and missing worktrees block launch rather than causing a reset
or checkout. Restore the recorded worktree/branch first. The prototype does not
delete branches, worktrees, backend conversations, or session records.

An external host for optional background execution is planned. Full descendant
process cleanup after an abrupt Emacs crash is not guaranteed by this adapter.
Stop requests interrupt the active turn and shut down the ACP transport; cleanup
of backend-spawned processes also depends on the backend. Reconcile any surviving
backend processes before resuming after a crash.

## Storage

`emacs-agents-directory` defaults to `emacs-agents/` under `user-emacs-directory`.
Set it before opening the registry. Keep it on a local filesystem. One Emacs
instance owns a registry at a time.

The SQLite database contains identifiers, paths, profile names, lifecycle state,
and diagnostics. Conversation history and credentials remain with the backend;
agent-shell also manages its own transcripts. Back up the registry together with
the backend's conversation storage. Keep profile definitions stable across
restarts; the package stores their identifiers, not credentials.

## Development

```sh
make test
make check
make test-integration ACP_LOAD_PATH='-L /path/to/agent-shell -L /path/to/acp -L /path/to/shell-maker'
```

Without `make`, run the corresponding commands directly:

```sh
emacs --batch -Q -L lisp -l test/emacs-agents-tests.el -f ert-run-tests-batch-and-exit
emacs --batch -Q -L lisp --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile lisp/*.el
emacs --batch -Q -L lisp -L /path/to/agent-shell -L /path/to/acp -L /path/to/shell-maker \
  -l test/emacs-agents-acp-tests.el -f ert-run-tests-batch-and-exit
```

Tests use disposable repositories, temporary databases, and a deterministic local
ACP subprocess. The integration suite tests restoration in two separate Emacs
processes and prevents conversation replacement on unsupported resume or missing
history. See [validation](docs/validation.md) for the tested environment and limits.

See [the design](docs/design.md) for the broader roadmap.

## Contributing

Ideas, bug reports, documentation, and patches are welcome. Prefer small changes
that make managing sessions more reliable and more natural in Emacs. Describe
the workflow a change enables and how its behavior can be checked.

## License

GNU General Public License, version 3 or (at your option) any later version.
See [LICENSE](LICENSE).
