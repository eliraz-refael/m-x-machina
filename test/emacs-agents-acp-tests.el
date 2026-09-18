;;; emacs-agents-acp-tests.el --- Real ACP transport tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'agent-shell)
(require 'agent-shell-mock-agent)
(load (expand-file-name "emacs-agents-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defun emacs-agents-test-wait (predicate)
  "Service subprocesses for up to ten seconds until PREDICATE holds."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall predicate))))

(defmacro emacs-agents-test-with-acp (&rest body)
  "Run BODY with a real agent-shell connected to the local fixture."
  (declare (indent 0) (debug t))
  `(emacs-agents-test-with-store
     (let ((shell-maker-root-path user-emacs-directory)
           (agent-shell-mock-agent-acp-command
            (list "python3" (expand-file-name "test/fake-acp.py" emacs-agents-test-root)
                  (expand-file-name "backend" temporary)))
           (agent-shell-agent-configs '(agent-shell-mock-agent-make-agent-config)))
       ,@body)))

(ert-deftest emacs-agents-acp-round-trip-stop-and-resume ()
  (emacs-agents-test-with-acp
    (let* ((id (emacs-agents-create "Demo" repo "mock-agent"))
           (buffer (emacs-agents-start id)))
      (emacs-agents-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
      (let ((saved (emacs-agents-session-conversation (emacs-agents-session id)))
            (run (emacs-agents-session-run (emacs-agents-session id))))
        (should (stringp saved))
        (should-not (kill-buffer buffer))
        (agent-shell-insert :text "Hello" :submit t :shell-buffer buffer :no-focus t)
        (emacs-agents-test-wait
         (lambda () (with-current-buffer buffer (string-match-p "Offline demo reply 1" (buffer-string)))))
        (emacs-agents-stop id)
        (should (equal (emacs-agents-session-status (emacs-agents-session id)) "stopped"))
        (emacs-agents-store-close)
        (setq buffer (emacs-agents-start id))
        (emacs-agents-test-wait
         (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
        (should (equal saved (emacs-agents-session-conversation (emacs-agents-session id))))
        (should-not (equal run (emacs-agents-session-run (emacs-agents-session id))))
        (agent-shell-insert :text "Again" :submit t :shell-buffer buffer :no-focus t)
        (emacs-agents-test-wait
         (lambda () (with-current-buffer buffer (string-match-p "Offline demo reply 2" (buffer-string)))))))))

(ert-deftest emacs-agents-acp-unsupported-resume-never-creates-replacement ()
  (emacs-agents-test-with-acp
    (setq agent-shell-mock-agent-acp-command
          (append agent-shell-mock-agent-acp-command '("unsupported")))
    (let* ((id (emacs-agents-create "Unsupported" repo "mock-agent"))
           (run (emacs-agents--begin-run id)))
      (emacs-agents--observe id run "stopped" "unknown" "saved-conversation")
      (emacs-agents-start id)
      (emacs-agents-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "failed")))
      (should (equal (emacs-agents-session-conversation (emacs-agents-session id)) "saved-conversation"))
      (with-temp-buffer
        (insert-file-contents (expand-file-name "backend/requests.jsonl" temporary))
        (should-not (string-match-p "session/new" (buffer-string)))))))

(ert-deftest emacs-agents-acp-missing-history-preserves-identity ()
  (emacs-agents-test-with-acp
    (let* ((id (emacs-agents-create "Missing" repo "mock-agent"))
           (run (emacs-agents--begin-run id)))
      (emacs-agents--observe id run "stopped" "unknown" "missing-conversation")
      (emacs-agents-start id)
      (emacs-agents-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "failed")))
      (should (equal (emacs-agents-session-conversation (emacs-agents-session id)) "missing-conversation"))
      (with-temp-buffer
        (insert-file-contents (expand-file-name "backend/requests.jsonl" temporary))
        (should (string-match-p "session/load" (buffer-string)))
        (should-not (string-match-p "session/new" (buffer-string)))))))

(ert-deftest emacs-agents-acp-resumes-in-a-new-emacs-process ()
  (emacs-agents-test-with-store
    (let ((args (append
                 '("--batch" "-Q")
                 (apply #'append
                        (mapcar (lambda (library) (list "-L" (file-name-directory (locate-library library))))
                                '("emacs-agents" "agent-shell" "acp" "shell-maker")))
                 (list "--eval" "(setq load-prefer-newer t)" "-l"
                       (expand-file-name "test/restart-phase.el" emacs-agents-test-root) temporary))))
      (dolist (phase '("create" "restore"))
        (with-temp-buffer
          (let ((result (apply #'call-process (expand-file-name invocation-name invocation-directory)
                               nil '(t t) nil (append args (list phase)))))
            (unless (equal result 0) (ert-fail (buffer-string)))
            (should (string-match-p (if (equal phase "create") "CREATED" "RESTORED") (buffer-string)))))))))

(ert-deftest emacs-agents-acp-offline-demo-is-reusable ()
  (emacs-agents-test-with-acp
    (load (expand-file-name "examples/demo.el" emacs-agents-test-root) nil t)
    (emacs-agents-demo)
    (let ((id (emacs-agents-session-id (car (emacs-agents-sessions)))))
      (emacs-agents-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
      (let ((saved (emacs-agents-session-conversation (emacs-agents-session id))))
        (emacs-agents-stop id)
        (emacs-agents-demo)
        (emacs-agents-test-wait
         (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
        (should (= (length (emacs-agents-sessions)) 1))
        (should (equal saved (emacs-agents-session-conversation (emacs-agents-session id))))))))

(ert-deftest emacs-agents-acp-process-exit-retires-run ()
  (emacs-agents-test-with-acp
    (let ((id (emacs-agents-create "Exit" repo "mock-agent")))
      (emacs-agents-start id)
      (emacs-agents-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
      (let ((saved (emacs-agents-session-conversation (emacs-agents-session id))))
        (delete-process (emacs-agents-backend-process (cdr (gethash id emacs-agents--running))))
        (emacs-agents--reconcile)
        (should-not (gethash id emacs-agents--running))
        (should (equal (emacs-agents-session-status (emacs-agents-session id)) "exited"))
        (should (equal saved (emacs-agents-session-conversation (emacs-agents-session id))))))))
