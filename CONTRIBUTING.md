# Contributing to M-x Machina

Bug reports, documentation and code contributions are welcome. For bugs, include
Emacs/OS and backend versions, reproduction steps and the diagnostic summary
(`i`, then `w`). Remove private paths or IDs as needed; do not post credentials
or private conversations. [Open an issue](https://github.com/eliraz-refael/m-x-machina/issues).

## Development

```sh
git clone https://github.com/eliraz-refael/m-x-machina.git
cd m-x-machina
git switch -c your-change
python3 scripts/check
```

Before submitting transport or messaging changes, run the full check:

```sh
python3 scripts/check --suite all --fetch-deps --build-vterm
```

See [testing](docs/testing.md) for dependencies and isolation. The offline fixtures
need no model account. Preserve session identity, drafts, permission prompts and
saved history; use explicit operations for destructive changes.

Packaging changes also require the [archive check](packaging/README.md):

```sh
python3 scripts/check-package --fetch-deps --all-transports --build-vterm
```

## Pull requests and merging

- All changes to `main` go through a pull request, including maintainer changes.
- CI must pass and the PR must be up to date with `main`.
- Resolve review conversations before merging.
- Use squash merge for a single logical change or rebase merge for a clean series.
  Merge commits, force pushes and deletion of `main` are disabled.
- Keep PRs focused and describe the problem, resulting behavior and validation.

To update a branch without introducing a merge commit:

```sh
git fetch origin
git rebase origin/main
```

If rebasing an already-pushed feature branch, coordinate with anyone sharing it
and use `git push --force-with-lease` on that feature branch, never on `main`.

This is an experimental project. Dependency compatibility and real-provider
restart validation remain tracked in [the backlog](docs/backlog.md).
