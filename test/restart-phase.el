;;; restart-phase.el --- One phase in a fresh Emacs -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(load (expand-file-name "mx-machina-acp-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(let* ((temporary (pop command-line-args-left))
       (phase (pop command-line-args-left))
       (user-emacs-directory (expand-file-name "child-emacs/" temporary))
       (shell-maker-root-path user-emacs-directory)
       (mx-machina-directory (expand-file-name "child-state/" temporary))
       (repo (expand-file-name "worktree/" temporary))
       (identity-file (expand-file-name "identity.el" temporary))
       (agent-shell-agent-configs '(agent-shell-mock-agent-make-agent-config))
       (agent-shell-mock-agent-acp-command
        (list "python3" (expand-file-name "test/fake-acp.py" mx-machina-test-root)
              (expand-file-name "child-backend/" temporary)))
       (saved (when (equal phase "restore")
                (with-temp-buffer (insert-file-contents identity-file) (read (current-buffer)))))
       (id (if saved (car saved) (mx-machina-create "Restart" repo "mock-agent"))))
  (when saved
    (should (equal (mx-machina-session-status (mx-machina-session id)) "stopped"))
    (should (equal (mx-machina-session-conversation (mx-machina-session id)) (cadr saved))))
  (mx-machina-start id)
  (mx-machina-test-wait
   (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
  (let ((s (mx-machina-session id)))
    (if saved
        (progn
          (should (equal (mx-machina-session-conversation s) (cadr saved)))
          (should-not (equal (mx-machina-session-run s) (caddr saved))))
      (with-temp-file identity-file
        (prin1 (list id (mx-machina-session-conversation s) (mx-machina-session-run s)) (current-buffer)))))
  ;; Let the actual kill-emacs-hook perform shutdown in each child.
  (princ (if saved "RESTORED\n" "CREATED\n")))
