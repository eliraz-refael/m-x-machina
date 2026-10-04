;;; emacs-agents-install-tests.el --- Standalone installation smoke checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'emacs-agents)
(unless (boundp 'emacs-agents-test-root)
  (load (expand-file-name "emacs-agents-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(ert-deftest emacs-agents-install-without-personal-configuration ()
  (should-not (featurep 'doom))
  (should-not user-init-file)
  (should (file-in-directory-p user-emacs-directory (getenv "EMACS_AGENTS_TEST_STATE")))
  (emacs-agents-test-with-store
    (emacs-agents)
    (should (derived-mode-p 'emacs-agents-sidebar-mode))
    (should-not (emacs-agents-sessions))
    (should (zerop (hash-table-count emacs-agents--running)))
    (when (equal (getenv "EMACS_AGENTS_TEST_SUITE") "core")
      (dolist (feature '(agent-shell eat vterm))
        (should-not (featurep feature))))))

(ert-deftest emacs-agents-install-doom-example-is-optional ()
  ;; The example guards optional packages; this does not claim a full Doom boot.
  (load (expand-file-name "examples/doom.el" emacs-agents-test-root) nil t)
  (should (fboundp 'emacs-agents))
  (should-not (featurep 'doom)))

(ert-deftest emacs-agents-install-mxm-reuses-existing-registry ()
  (emacs-agents-test-with-store
    (let* ((id (emacs-agents-create "Existing agent" repo "test" "Work"))
           (directory emacs-agents-directory))
      (emacs-agents-store-close)
      (require 'mxm)
      (dolist (command '(mxm mxm-new mxm-board mxm-dashboard mxm-messaging-mode))
        (should (commandp command)))
      (call-interactively #'mxm)
      (should (equal emacs-agents-directory directory))
      (should (equal (mapcar #'emacs-agents-session-id (emacs-agents-sessions)) (list id)))
      (should (equal (emacs-agents-session-name (emacs-agents-session id)) "Existing agent"))
      (should (zerop (hash-table-count emacs-agents--running))))))
