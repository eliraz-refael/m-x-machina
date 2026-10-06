# MELPA submission preparation

M-x Machina is **not yet on MELPA**. The recipe in [mx-machina](mx-machina)
packages the Lisp libraries and runtime helpers; optional agent interfaces remain
separate installations. Git checkouts and installed archives are both supported.

## Reproduce the archive check

From the project root:

```sh
python3 scripts/check-package --fetch-deps
# Also exercise installed ACP, EAT, vterm, hook events and CLI messaging:
python3 scripts/check-package --fetch-deps --all-transports --build-vterm
```

Requirements: Emacs 29.1+ with SQLite, Python 3, Git, tar and GNU timeout.
The full check also needs the [native terminal build tools](../docs/testing.md).
`--emacs /path/to/emacs` selects the runtime. Once dependencies are cached,
omit `--fetch-deps` and `--build-vterm` to avoid downloading/rebuilding them.

The runner uses the revisions of package-build and package-lint pinned in
[tools.json](tools.json), current when checked on 2026-10-06, plus the pinned
compat library. It runs checkdoc and package-lint, builds the exact recipe using
MELPA's package-build, verifies its contents, and installs with
`package-install-file` in a disposable home. It deletes the build checkout
before installation and checks generated autoloads and compiled libraries in a
fresh Emacs. The regression suite then uses the installed package, including
its actual scripts. Tests do not load personal configuration or start providers.

To test unpublished changes, the builder uses a committed snapshot of local
package inputs with fetching disabled; the recipe itself is unchanged. This
checks packaging and runtime layout, **not upstream fetching or release version
detection**. The resulting `.cache/package/mx-machina-*.tar` is a test artifact,
not an announced release. `--output DIRECTORY` changes that destination.

### Documented package-lint exceptions

Seven `with-eval-after-load` warnings remain deliberate:

- Two in `mx-machina-agent-shell.el` attach integration advice only after the
  optional agent-shell/ACP libraries load.
- Five in `mx-machina-doom.el` apply explicitly requested Evil/Doom bindings
  after Evil and the relevant keymaps become available. Requiring this opt-in
  library does not install or eagerly load those optional packages.

`test/packaging/lint.el` permits only that warning for those file/feature pairs,
prints every exception, and fails on all other package-lint or checkdoc findings.
Checkdoc runs without spelling or its experimental verb heuristic (older Emacs
misidentifies nouns such as "changes"). Byte-compilation warnings are errors. Disclose these exceptions to MELPA reviewers;
they may request a different integration approach.

## Before submitting

Follow the current [MELPA contribution guide](https://github.com/melpa/melpa/blob/master/CONTRIBUTING.org)
and [new-package checklist](https://github.com/melpa/melpa/blob/master/.github/PULL_REQUEST_TEMPLATE.md),
which may change before submission.

- [ ] Complete at least one month of public repository maintenance.
- [ ] The human maintainer thoroughly reviews the AI-assisted code and verifies
  the `Assisted-by:` attribution. Automated checks do not satisfy human review.
- [ ] Update the tool pins to the latest versions and rerun required checks.
- [ ] After these changes are on the public default branch, copy the recipe to
  a MELPA checkout and run `make recipes/mx-machina` with normal upstream fetching.
  Install that archive in a fresh Emacs using `M-x package-install-file`.
- [ ] Open a recipe PR against `melpa/melpa`, titled **Add recipe for mx-machina**.
  Explain the optional integrations and documented lint exceptions. Complete
  each upstream checkbox truthfully and respond to the maintainers' review.

Only `recipes/mx-machina` belongs in the MELPA PR. Package source changes stay
in this repository. Normal MELPA follows upstream development; MELPA Stable
additionally requires a suitable version tag and a tested stable build.
