EMACS ?= emacs
PYTHON ?= python3
CHECK_FLAGS ?=

.PHONY: test check test-all test-integration test-eat test-vterm test-messaging
# No downloads or installed adapters needed; compilation is included.
test check:
	$(PYTHON) scripts/check --emacs "$(EMACS)" $(CHECK_FLAGS)

# Full release gate, including a separately built native vterm module.
test-all test-messaging:
	$(PYTHON) scripts/check --emacs "$(EMACS)" --suite all --fetch-deps --build-vterm $(CHECK_FLAGS)

test-integration:
	$(PYTHON) scripts/check --emacs "$(EMACS)" --suite acp --fetch-deps $(CHECK_FLAGS)

test-eat:
	$(PYTHON) scripts/check --emacs "$(EMACS)" --suite eat --fetch-deps $(CHECK_FLAGS)

test-vterm:
	$(PYTHON) scripts/check --emacs "$(EMACS)" --suite vterm --fetch-deps --build-vterm $(CHECK_FLAGS)
