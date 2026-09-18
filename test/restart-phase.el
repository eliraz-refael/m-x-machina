;;; restart-phase.el --- One phase in a fresh Emacs -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(load (expand-file-name "emacs-agents-acp-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(let* ((temporary (pop command-line-args-left))
       (phase (pop command-line-args-left))
       (user-emacs-directory (expand-file-name "child-emacs/" temporary))
       (shell-maker-root-path user-emacs-directory)
       (emacs-agents-directory (expand-file-name "child-state/" temporary))
       (repo (expand-file-name "worktree/" temporary))
       (identity-file (expand-file-name "identity.el" temporary))
       (agent-shell-agent-configs '(agent-shell-mock-agent-make-agent-config))
       (agent-shell-mock-agent-acp-command
        (list "python3" (expand-file-name "test/fake-acp.py" emacs-agents-test-root)
              (expand-file-name "child-backend/" temporary)))
       (saved (when (equal phase "restore")
                (with-temp-buffer (insert-file-contents identity-file) (read (current-buffer)))))
       (id (if saved (car saved) (emacs-agents-create "Restart" repo "mock-agent"))))
  (when saved
    (should (equal (emacs-agents-session-status (emacs-agents-session id)) "stopped"))
    (should (equal (emacs-agents-session-conversation (emacs-agents-session id)) (cadr saved))))
  (emacs-agents-start id)
  (emacs-agents-test-wait
   (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
  (let ((s (emacs-agents-session id)))
    (if saved
        (progn
          (should (equal (emacs-agents-session-conversation s) (cadr saved)))
          (should-not (equal (emacs-agents-session-run s) (caddr saved))))
      (with-temp-file identity-file
        (prin1 (list id (emacs-agents-session-conversation s) (emacs-agents-session-run s)) (current-buffer)))))
  ;; Let the actual kill-emacs-hook perform shutdown in each child.
  (princ (if saved "RESTORED\n" "CREATED\n")))
