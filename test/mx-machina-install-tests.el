;;; mx-machina-install-tests.el --- Standalone installation smoke checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'mx-machina)
(unless (boundp 'mx-machina-test-root)
  (load (expand-file-name "mx-machina-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(ert-deftest mx-machina-install-without-personal-configuration ()
  (should-not (featurep 'doom))
  (should-not user-init-file)
  (should (file-in-directory-p user-emacs-directory (getenv "EMACS_AGENTS_TEST_STATE")))
  (mx-machina-test-with-store
    (mx-machina)
    (should (derived-mode-p 'mx-machina-sidebar-mode))
    (should-not (mx-machina-sessions))
    (should (zerop (hash-table-count mx-machina--running)))
    (when (equal (getenv "EMACS_AGENTS_TEST_SUITE") "core")
      (dolist (feature '(agent-shell eat vterm))
        (should-not (featurep feature))))))

(ert-deftest mx-machina-install-doom-example-is-optional ()
  ;; The example guards optional packages; this does not claim a full Doom boot.
  (load (expand-file-name "examples/doom.el" mx-machina-test-root) nil t)
  (should (commandp 'mx-machina))
  (should-not (featurep 'doom)))

(ert-deftest mx-machina-install-reopens-pre-rename-registry ()
  (mx-machina-test-with-store
    (make-directory mx-machina-directory t)
    (let ((db (sqlite-open (expand-file-name "sessions.sqlite" mx-machina-directory))))
      (unwind-protect
          (with-temp-buffer
            (insert-file-contents (expand-file-name "test/fixtures/legacy-registry.sql" mx-machina-test-root))
            (dolist (statement (split-string (buffer-string) ";" t "[[:space:]]+"))
              (sqlite-execute db statement)))
        (sqlite-close db)))
    (let ((session (mx-machina-session "legacy-agent-id")))
      (should (equal (mx-machina-session-name session) "Saved agent"))
      (should (equal (mx-machina-session-profile session) "claude-eat-work"))
      (should (equal (mx-machina-session-directory session) "/tmp/saved-worktree/"))
      (should (equal (mx-machina-session-branch session) "feature/saved"))
      (should (equal (mx-machina-session-folder session) "Work/Panel"))
      (should (equal (mx-machina-session-conversation session) "saved-conversation"))
      (should (equal (mx-machina-session-model session) "saved-model")))
    (mx-machina)
    (should (equal (buffer-name) "*M-x Machina Sidebar*"))
    (should (zerop (hash-table-count mx-machina--running)))))

(ert-deftest mx-machina-install-autoloads-ignore-legacy-library-collisions ()
  ;; A fresh Emacs is essential: this runner has already required the package.
  (mx-machina-test-with-store
    (let* ((lisp (expand-file-name "lisp" mx-machina-test-root))
           (autoloads (expand-file-name "loaddefs.el" temporary))
           (probe (expand-file-name "probe.el" temporary)))
      (dolist (name '("emacs-agents.el" "mxm.el"))
        (write-region "(error \"Loaded another package's library\")" nil
                      (expand-file-name name temporary) nil 'silent))
      (with-temp-file probe
        (prin1
         `(progn
            (require 'ert)
            (require 'loaddefs-gen)
            (setq user-emacs-directory ,user-emacs-directory)
            (loaddefs-generate ,lisp ,autoloads)
            (load ,autoloads nil t)
            (should-not (featurep 'mx-machina))
            (dolist (command '(mx-machina mx-machina-new mx-machina-new-folder mx-machina-move
                              mx-machina-rename mx-machina-mark-read mx-machina-open
                              mx-machina-stop mx-machina-archive mx-machina-archived
                              mx-machina-restore mx-machina-delete mx-machina-refresh
                              mx-machina-files mx-machina-magit mx-machina-details
                              mx-machina-board mx-machina-actions mx-machina-next-attention
                              mx-machina-previous-attention mx-machina-next-waiting
                              mx-machina-previous-waiting mx-machina-next-unread
                              mx-machina-previous-unread mx-machina-eshell mx-machina-focus
                              mx-machina-dashboard mx-machina-close-view mx-machina-diagnostics
                              mx-machina-rebind-worktree mx-machina-retry mx-machina-transcript
                              mx-machina-status-mode mx-machina-messaging-mode
                              mx-machina-messaging-ready))
              (should (commandp command)))
            (mx-machina)
            (should (featurep 'mx-machina))
            (should (equal mx-machina-directory
                           (expand-file-name "emacs-agents/" user-emacs-directory)))
            (should-not (featurep 'emacs-agents))
            (should-not (featurep 'mxm))
            (mapatoms (lambda (symbol)
                        (when (or (string-prefix-p "emacs-agents" (symbol-name symbol))
                                  (string-match-p "\\`mxm\\(?:-\\|\\'\\)" (symbol-name symbol)))
                          (should-not (fboundp symbol))
                          (should-not (boundp symbol)))))
            (mx-machina-shutdown))
         (current-buffer)))
      (with-temp-buffer
        (let ((result (call-process (expand-file-name invocation-name invocation-directory)
                                    nil (current-buffer) nil "--batch" "-Q"
                                    "-l" (expand-file-name "test/bootstrap.el" mx-machina-test-root)
                                    "-L" lisp "-L" temporary "-l" probe)))
          (ert-info ((buffer-string)) (should (equal result 0))))))))
