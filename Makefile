EMACS ?= emacs
# Supply -L directories for installed agent-shell, acp, and shell-maker.
ACP_LOAD_PATH ?=
EAT_LOAD_PATH ?=
VTERM_LOAD_PATH ?=

.PHONY: test check test-integration test-eat test-vterm
test:
	$(EMACS) --batch -Q -L lisp --eval '(setq load-prefer-newer t)' -l test/emacs-agents-archive-tests.el -f ert-run-tests-batch-and-exit

check:
	$(EMACS) --batch -Q -L lisp --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile lisp/*.el

test-integration:
	$(EMACS) --batch -Q -L lisp $(ACP_LOAD_PATH) --eval '(setq load-prefer-newer t)' -l test/emacs-agents-acp-tests.el -f ert-run-tests-batch-and-exit

test-eat:
	$(EMACS) --batch -Q -L lisp $(EAT_LOAD_PATH) --eval '(setq load-prefer-newer t)' -l test/emacs-agents-eat-tests.el -l test/emacs-agents-transcript-tests.el -f ert-run-tests-batch-and-exit

test-vterm:
	$(EMACS) --batch -Q -L lisp $(EAT_LOAD_PATH) $(VTERM_LOAD_PATH) --eval '(setq load-prefer-newer t)' -l test/emacs-agents-vterm-tests.el --eval '(ert-run-tests-batch-and-exit "emacs-agents-vterm-")'
