;;; emacs-agents-tests.el --- Registry and lifecycle tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'emacs-agents)

(defconst emacs-agents-test-root
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))

(defmacro emacs-agents-test-with-store (&rest body)
  "Run BODY with an isolated registry and committed Git worktree."
  (declare (indent 0) (debug t))
  `(let* ((temporary (make-temp-file "emacs-agents-test-" t))
          (user-emacs-directory (expand-file-name "emacs/" temporary))
          (emacs-agents-directory (expand-file-name "state/" temporary))
          (emacs-agents--db nil) (emacs-agents--db-file nil)
          (emacs-agents--running (make-hash-table :test #'equal))
          (emacs-agents--timer nil)
          (repo (expand-file-name "worktree/" temporary)))
     (unwind-protect
         (progn
           (make-directory repo)
           (emacs-agents--git repo "init" "-b" "main")
           (emacs-agents--git repo "-c" "user.name=Fixture" "-c" "user.email=fixture@example.invalid"
                              "-c" "commit.gpgsign=false" "commit" "--allow-empty" "-m" "Fixture")
           ,@body)
       (emacs-agents-shutdown)
       (dolist (buffer (buffer-list))
         (when (or (equal (buffer-name buffer) "*Emacs Agents*")
                   (buffer-local-value 'emacs-agents--managed-id buffer))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))))
       (delete-directory temporary t))))

(ert-deftest emacs-agents-registry-persists-identity-and-recovers-status ()
  (emacs-agents-test-with-store
    (let* ((id (emacs-agents-create "O'Brien" repo "test-account"))
           (run (emacs-agents--begin-run id)))
      (emacs-agents--observe id run "live" "working" "conversation-123")
      (emacs-agents-store-close)
      (let ((session (emacs-agents-session id)))
        (should (equal (emacs-agents-session-name session) "O'Brien"))
        (should (equal (emacs-agents-session-conversation session) "conversation-123"))
        (should (equal (emacs-agents-session-profile session) "test-account"))
        (should (equal (emacs-agents-session-status session) "stopped"))
        (should (equal (emacs-agents-session-activity session) "unknown")))
      (should (equal (caar (emacs-agents--query "SELECT outcome FROM runs WHERE id=?" run)) "disconnected")))))

(ert-deftest emacs-agents-stale-and-terminal-events-cannot-resurrect-runs ()
  (emacs-agents-test-with-store
    (let* ((id (emacs-agents-create "Test" repo "test"))
           (old (emacs-agents--begin-run id)))
      (emacs-agents--observe id old "stopped" "unknown" "conversation")
      (let ((new (emacs-agents--begin-run id)))
        (should-not (emacs-agents--observe id old "live" "working"))
        (emacs-agents--observe id new "failed" "unknown" nil "Resume failed")
        (should-not (emacs-agents--observe id new "live" "input"))
        (should (equal (emacs-agents-session-status (emacs-agents-session id)) "failed"))))))

(ert-deftest emacs-agents-conversation-mismatch-preserves-original ()
  (emacs-agents-test-with-store
    (let* ((id (emacs-agents-create "Test" repo "test"))
           (run (emacs-agents--begin-run id)))
      (emacs-agents--observe id run "live" "input" "original")
      (should-error (emacs-agents--observe id run "live" "input" "replacement"))
      (should (equal (emacs-agents-session-conversation (emacs-agents-session id)) "original")))))

(ert-deftest emacs-agents-branch-change-blocks-launch ()
  (emacs-agents-test-with-store
    (let ((id (emacs-agents-create "Test" repo "test")))
      (emacs-agents--git repo "checkout" "-b" "different")
      (should-error (emacs-agents-start id) :type 'user-error)
      (should-not (emacs-agents-session-run (emacs-agents-session id))))))

(ert-deftest emacs-agents-unconfirmed-identity-blocks-replacement ()
  (emacs-agents-test-with-store
    (let* ((id (emacs-agents-create "Test" repo "test"))
           (run (emacs-agents--begin-run id)))
      (emacs-agents--observe id run "stopped" "unknown")
      (should-error (emacs-agents-start id) :type 'user-error))))

(ert-deftest emacs-agents-dashboard-is-read-only-and-does-not-launch ()
  (emacs-agents-test-with-store
    (let ((id (emacs-agents-create "Test" repo "test")))
      (emacs-agents)
      (with-current-buffer "*Emacs Agents*"
        (should buffer-read-only)
        (should (equal (caar tabulated-list-entries) id))
        (should (string-match-p "Test" (buffer-string))))
      (should (zerop (hash-table-count emacs-agents--running)))
      (should-not (emacs-agents-session-run (emacs-agents-session id))))))

(ert-deftest emacs-agents-guard-rejects-fallback-and-wrong-conversations ()
  (dolist (request '(((:method . "session/new"))
                     ((:method . "session/list"))
                     ((:method . "session/load") (:params . ((sessionId . "wrong"))))))
    (let* (failure
           (transport (emacs-agents--transport-create
                       :conversation "original"
                       :callback (lambda (&rest args) (setq failure args)))))
      (should-error (emacs-agents--guard-request transport request))
      (should (equal (car failure) "failed")))))

(ert-deftest emacs-agents-guard-allows-only-saved-resume ()
  (let* ((transport (emacs-agents--transport-create :conversation "saved"))
         (request '((:method . "session/load") (:params . ((sessionId . "saved"))))))
    (should (eq request (emacs-agents--guard-request transport request)))))

(ert-deftest emacs-agents-refuses-newer-schema ()
  (emacs-agents-test-with-store
    (emacs-agents--exec "PRAGMA user_version=99")
    (emacs-agents-store-close)
    (should-error (emacs-agents-store-open))
    (should-not emacs-agents--db)))
