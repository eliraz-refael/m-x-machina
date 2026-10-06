# Isolated checks and dependency compatibility

The release check is:

```sh
python3 scripts/check --suite all --fetch-deps --build-vterm
```

For core development, `python3 scripts/check` needs only Emacs 29.1+ with SQLite,
Git and Python 3. It includes byte compilation, registry/UI/recovery tests,
transcripts, message-queue unit tests and standalone installation smoke tests.
It prints a skip line for each unselected optional suite.

## Dependency setup

`test/dependencies.json` pins the six external Lisp dependencies by full Git SHA.
The downloader uses separate checkouts under `.cache/test-deps/NAME/SHA`, preserves
upstream symlinks and checks the revision and tracked-file cleanliness on reuse.
It refuses stray compiled Lisp files so source and bytecode cannot accidentally
come from different versions. `--deps-dir PATH` can relocate this test cache.
The cache is ignored by Git and can be deleted to start fresh.

For the native vterm check install build tools using your usual development
environment: CMake, a C compiler, Make and GNU libtool. `tic` from ncurses builds
EAT's terminal definitions. The runner follows [vterm's native build procedure](https://github.com/akermu/emacs-libvterm#manual-installation)
and chooses its pinned bundled libvterm instead of a system copy. Its first
native build needs network access; runtime tests use local Python fixtures.
Existing installed EAT/vterm/agent-shell packages are not used or rebuilt.

Targeted checks include the core suite:

```sh
python3 scripts/check --suite acp --fetch-deps
python3 scripts/check --suite eat --fetch-deps
python3 scripts/check --suite vterm --fetch-deps --build-vterm
python3 scripts/check --suite all
python3 scripts/check --emacs /path/to/another/emacs
```

Missing dependencies, failed downloads, compilation warnings, native module load
failures and failing tests produce a nonzero exit status. No optional adapter is
silently omitted from `--suite all`.

## Isolation

Checks run in a disposable copy of the package. They never write compiled Lisp
into the checkout or install packages into an Emacs profile. A bootstrap loaded
before the package redirects Emacs state, customization, package storage, native
compilation output and server paths to a private temporary directory. `-Q`
skips personal initialization. Fixture Git commands ignore personal Git config.
The CLI finds the `emacsclient` paired with the selected Emacs binary.

Messaging tests bind a private server name and socket directory and contain all
server shutdown hooks within the fixture, including socket creation failure.
The default core suite does not open a server socket. The test runner does not
change the user's HOME or connect to a running Emacs session.

## CI and what it establishes

`.github/workflows/check.yml` uses pinned action revisions and read-only repository
permissions. It runs:

| Job | OS | Emacs | Coverage |
| --- | --- | --- | --- |
| Core | Linux | 29.1, 30.2, 31.1 | Compile, core, standalone load |
| Core | macOS | 31.1 | Compile, core, standalone load |
| Transports | Linux | 29.1, 31.1 | All suites, freshly built vterm, private CLI server |

[setup-emacs](https://github.com/purcell/setup-emacs) supplies the CI Emacs binary.
The `Required checks` gate succeeds only when all core and transport jobs
succeed; failed, cancelled or skipped jobs block it.
The complete hosted matrix [passed on 2026-10-04](https://github.com/eliraz-refael/m-x-machina/actions/runs/37234024596):
88 core tests per core job and 128 tests per full transport job, with all 17 Lisp
files compiled using warnings as errors. Results and limits live in `validation.md`.

[Installation checks](installation.md#reproduce-the-installation-checks) also
boot and restart fresh plain Emacs and Doom installations, including Evil keys
and native vterm loading. The real-provider restart/permission pilot remains
release work. No user's running Doom is restarted or changed by these checks.

The required archive jobs run `scripts/check-package` on Linux Emacs 29.1 and
31.1. They lint, build the MELPA recipe, install the archive, check generated
autoloads and bytecode, and run all transport regressions against installed
resources with the build checkout removed. Checkout-only installation tests are
covered by the existing jobs. See [packaging](../packaging/README.md) for tool
pins, the seven documented optional-integration lint exceptions and reproduction.

When updating dependencies, edit the pins deliberately, rerun the full suite, and
record versions and results. Test dependency upgrades in a fresh Emacs: reloading
only part of agent-shell can leave old callbacks in existing buffers and produce
misleading permission or busy states.
