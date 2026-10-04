;;; bootstrap.el --- Disposable batch test state -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Load before the package or any dependency, with emacs --batch -Q.
;;; Code:
(require 'cl-lib)
(let ((state (getenv "EMACS_AGENTS_TEST_STATE")))
  (unless (and noninteractive state (file-name-absolute-p state))
    (error "Use scripts/check to create isolated test state"))
  (setq user-emacs-directory (file-name-as-directory state)
        custom-file (expand-file-name "custom.el" state)
        package-user-dir (expand-file-name "elpa/" state)
        url-configuration-directory (expand-file-name "url/" state)
        server-name "isolated-check"
        server-socket-dir (expand-file-name "server/" state)
        server-auth-dir (expand-file-name "server-auth/" state)
        load-prefer-newer t)
  (make-directory user-emacs-directory t)
  (set-file-modes user-emacs-directory #o700))
(when (fboundp 'startup-redirect-eln-cache)
  (startup-redirect-eln-cache (expand-file-name "eln-cache/" user-emacs-directory)))
(require 'sqlite)
(unless (sqlite-available-p) (error "Tests require Emacs built with SQLite"))
;; Never invoke vterm's interactive auto-build in a dependency checkout.
(setq vterm-always-compile-module nil)
(advice-add 'yes-or-no-p :override
            (lambda (&rest _) (error "Unexpected interactive prompt in batch checks")))
(message "Test runtime: Emacs %s, SQLite enabled, isolated state %s"
         emacs-version user-emacs-directory)
;;; bootstrap.el ends here
