# Installation

M-x Machina is loaded from a Git checkout. It is not currently distributed through
ELPA or MELPA. Its sidebar works without an agent package; choose an interface
before starting a real agent.

## Prerequisites

- Emacs 29.1 or later with SQLite. Evaluate `(sqlite-available-p)` with `M-:`;
  it must return `t`. Installing a separate `sqlite3` command does not add SQLite
  support to an Emacs built without it.
- Git, and a worktree containing at least one commit.
- Python 3 for the terminal status bridge, CLI messaging and offline demo.
- For real agents, the provider executable and authentication for the selected
  profile. The package does not install providers or manage credentials.

Clone anywhere convenient and use its **absolute path** in the examples below:

```sh
git clone https://github.com/eliraz-refael/m-x-machina.git
```

## Plain Emacs

Put this in `init.el`, adjusting the path, and restart Emacs:

```elisp
(add-to-list 'load-path "/absolute/path/to/m-x-machina/lisp")
(require 'mx-machina)
```

Run `M-x mx-machina`. An empty sidebar is expected on the first launch. No agent
process starts until you explicitly open an agent.

Install only the interfaces you want. With Emacs's built-in package manager,
add MELPA for agent-shell or vterm; EAT is available from NonGNU ELPA:

```elisp
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(add-to-list 'package-archives '("nongnu" . "https://elpa.nongnu.org/nongnu/") t)
(package-initialize)
```

Evaluate this configuration, run `M-x package-refresh-contents`, then use
`M-x package-install` for `eat`, `vterm`, or `agent-shell`. The package manager
installs their Lisp dependencies. Archive versions change: the tested revisions
are listed below, not a promise that every future archive update is compatible.

| Interface | Additional setup |
| --- | --- |
| EAT | Install and authenticate Claude Code; ensure Emacs can find `claude` and `python3`. |
| vterm | Build its native module as described below; install and authenticate Claude Code. |
| agent-shell | Install an ACP provider supported by agent-shell and configure its authentication. Claude's ACP adapter is separate from the `claude` terminal executable. Follow [agent-shell's provider instructions](https://github.com/xenodium/agent-shell#requirements). |

Check executable visibility **inside Emacs**, for example with
`M-: (executable-find "claude")` and `M-: (executable-find "python3")`.
A GUI Emacs can have a different `PATH` from your shell. Correct `exec-path`
and the environment in your own configuration if either returns `nil`.

For a no-account trial, install agent-shell and load `examples/demo.el`, then
run `M-x mx-machina-demo`. This uses a local Python fixture, not a commercial
provider. See the [offline demo](../README.md#offline-demo) for interaction keys.

## Doom Emacs

Start from a working [Doom installation](https://github.com/doomemacs/core#install).
Keep your existing `init.el`, modules and account configuration.

If your interfaces are already installed, go straight to the `config.el` step.
Otherwise, this optional dependency bundle installs the pinned EAT, vterm and
agent-shell versions tested together. Add to **Doom's `packages.el`**:

```elisp
(load! "/absolute/path/to/m-x-machina/examples/doom-packages.el")
```

The bundle includes all three interfaces. If you only want one, copy its recipe
and dependencies from that file instead: EAT needs compat; agent-shell needs ACP
and shell-maker; vterm needs native build tools. Avoid declaring the same package
twice in your own `packages.el`. The vterm recipe also works with Doom's existing
`:term vterm` module.

Add to **Doom's `config.el`**:

```elisp
(load! "/absolute/path/to/m-x-machina/examples/doom.el")
```

Run your Doom installation's `bin/doom sync` after changing `packages.el` or
enabled modules, then restart Emacs. For a literate configuration, edit the
source Org file so tangling does not discard the load form. Do not put the
`package-initialize` snippet from the plain Emacs section into Doom.

With Evil enabled, `SPC o a a` opens the sidebar, `SPC o a n` creates an agent,
`SPC o a b` opens the board, and `SPC o a ?` shows contextual actions. The
`M-x mx-machina` commands work independently of those leader bindings.

## Building vterm

Evaluate `M-: module-file-suffix`. If it is `nil`, use an Emacs build with dynamic
module support. A Lisp-only installation of vterm cannot provide a terminal.

Install a C compiler, CMake and the platform's libtool tools. Common examples:

```sh
# Debian / Ubuntu
sudo apt install build-essential cmake libtool-bin

# macOS with Homebrew; Apple's command-line developer tools provide the compiler
xcode-select --install
brew install cmake libtool
```

Then evaluate `M-: (require 'vterm)` and accept its first-use compilation prompt.
The build may download libvterm. Verify `M-: (require 'vterm-module nil t)` returns
non-nil. Compile with the same Emacs and CPU architecture that will run it;
rebuild after changing those. Other package managers can provide the equivalent
tools or a prebuilt module. See the [upstream vterm installation guide](https://github.com/akermu/emacs-libvterm#installation).

## Tested dependency set

The exact commits are in [test/dependencies.json](../test/dependencies.json).
[examples/doom-packages.el](../examples/doom-packages.el) pins the same revisions.

| Component | Tested version / revision |
| --- | --- |
| agent-shell | 0.83.4 |
| ACP | 0.15.2 |
| shell-maker | 0.97.5 |
| EAT | 0.9.4, `c8d54d6` |
| compat | `90880f8` |
| vterm | `7092111` with a locally compiled native module |
| Doom core | 2.2.4, `59cdaa3`, with Evil, vterm and default bindings enabled |

The adapter uses some agent-shell internals, so updates deserve compatibility
testing. EAT's installation must include its `term/`, `terminfo/` and integration
resources; copying just `eat.el` is insufficient.

## Troubleshooting

| Symptom | Check / action |
| --- | --- |
| `Cannot open load file: mx-machina` | Point `load-path` at the checkout's **lisp/** directory, not its root. |
| `Emacs needs SQLite support` | Check `(sqlite-available-p)` in this Emacs build. |
| `Install EAT` or `Install vterm` | Install the selected optional package, run `doom sync` if applicable, then restart. |
| vterm compilation/module load fails | Check the compiler, CMake, libtool, Emacs module support and CPU architecture; inspect vterm's compilation buffer. |
| Provider executable is missing | Use `executable-find` in Emacs; fix the profile's command or Emacs environment. |
| A saved profile is unavailable | Restore the profile definition with the same ID and account; do not silently substitute another account. |
| Old `emacs-agents-*` command errors after updating | Follow the [namespace migration](../README.md#commands-and-compatibility), rebuild stale package bytecode/autoloads, then restart. |

For an existing agent, `i` opens diagnostics without launching it; `w` copies a
summary that omits credentials and conversation text.

## Reproduce the installation checks

From this checkout, on macOS or Linux:

```sh
python3 scripts/check-install                     # no optional packages
python3 scripts/check-install --kind plain-adapters  # fresh pinned dependencies
python3 scripts/check-install --kind doom         # fresh Doom + pinned adapters
```

The last two commands require network access and vterm's build tools. The Doom
check follows its pinned core revision and that revision's module/package pins;
upstream recipe indexes are fetched by Doom. These are compatibility checks,
not an entirely offline or hermetic distribution of Doom.

Each command creates a disposable home, configuration, caches and registry,
boots a real interactive Emacs in a private terminal, and restarts it to verify
a saved fixture agent. Doom additionally checks Evil navigation and leader keys;
adapter checks load the actual native vterm module. No real model is launched
and no personal config or package installation is used. `--emacs /path/to/emacs`
selects another Emacs; `--keep` retains the temporary installation and logs for
inspection. Full transport behavior is covered separately by `scripts/check`.
