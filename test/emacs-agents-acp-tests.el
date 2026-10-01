;;; emacs-agents-acp-tests.el --- Real ACP transport tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'agent-shell)
(require 'agent-shell-mock-agent)
(unless (boundp 'emacs-agents-test-root)
  (load (expand-file-name "emacs-agents-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t))

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

(ert-deftest emacs-agents-acp-prompt-in-focus-keeps-layout-and-live-counts ()
  (emacs-agents-test-with-acp
    (let ((id (emacs-agents-create "Focused" repo "mock-agent")))
      (emacs-agents-open id)
      (emacs-agents-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
      (let ((buffer (current-buffer)))
        (should (string-match-p "1 ready" emacs-agents--summary))
        (emacs-agents-focus id)
        (agent-shell-insert :text "Work while I focus" :submit t :shell-buffer buffer :no-focus t)
        (emacs-agents-test-wait
         (lambda () (with-current-buffer buffer (string-match-p "Offline demo reply 1" (buffer-string)))))
        (emacs-agents-test-wait
         (lambda () (string-match-p "1 ready" emacs-agents--summary)))
        (should (= (length (window-list)) 1))
        (should (eq (current-buffer) buffer))
        (emacs-agents-focus)
        (should (get-buffer-window "*Agent Overview*"))
        (should (eq (current-buffer) buffer))
        (should-not (window-parameter nil 'window-side))
        (emacs-agents-close-view)
        (should (gethash id emacs-agents--running))
        (should (buffer-live-p buffer))
        (should-not (get-buffer-window buffer))
        (emacs-agents-stop id)
        (should (string-match-p "1 stopped" emacs-agents--summary))))))

(ert-deftest emacs-agents-acp-hidden-reply-is-unread-with-reported-model-header ()
  (emacs-agents-test-with-acp
    (let* ((id (emacs-agents-create "Harness" repo "mock-agent" "Work/Wix Panels"))
           (buffer (emacs-agents-start id)))
      (emacs-agents-test-wait
       (lambda () (equal (emacs-agents-session-model (emacs-agents-session id)) "Offline fixture")))
      (emacs-agents)
      (agent-shell-insert :text "A reply while hidden" :submit t :shell-buffer buffer :no-focus t)
      (emacs-agents-test-wait
       (lambda () (equal (emacs-agents-session-activity (emacs-agents-session id)) "input")))
      (should (emacs-agents-unread-p (emacs-agents-session id)))
      (with-current-buffer "*Agent Overview*"
        (should (string-match-p "NEW" (buffer-string))))
      (emacs-agents-open id)
      (with-current-buffer buffer
        (should (string-match-p "Harness" emacs-agents--identity))
        (should (string-match-p "Offline fixture" emacs-agents--identity))
        (should (string-match-p "Project: worktree" emacs-agents--identity))
        (should (string-match-p "Branch: main" emacs-agents--context))
        (should (string-match-p "Work/Wix Panels" emacs-agents--context))
        (agent-shell--update-header-and-mode-line)
        (should (equal header-line-format '(:eval emacs-agents--context))))
      (emacs-agents-mark-read id)
      (emacs-agents-stop id)
      (emacs-agents-open id)
      (emacs-agents-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
      (should-not (emacs-agents-unread-p (emacs-agents-session id))))))

(ert-deftest emacs-agents-acp-simulated-work-finishes-and-can-be-cancelled ()
  (emacs-agents-test-with-acp
    (let* ((id (emacs-agents-create "Working demo" repo "mock-agent"))
           (buffer (emacs-agents-start id)))
      (emacs-agents-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
      (let ((conversation (emacs-agents-session-conversation (emacs-agents-session id))))
        (emacs-agents)
        (agent-shell-insert :text "/work 1" :submit t :shell-buffer buffer :no-focus t)
        (emacs-agents-test-wait
         (lambda () (with-current-buffer buffer (string-match-p "Simulating work for 1 seconds" (buffer-string)))))
        (should (equal (emacs-agents-session-activity (emacs-agents-session id)) "working"))
        (should (string-match-p "1 working" emacs-agents--summary))
        (emacs-agents-test-wait
         (lambda () (equal (emacs-agents-session-activity (emacs-agents-session id)) "input")))
        (should (emacs-agents-unread-p (emacs-agents-session id)))
        (agent-shell-insert :text "/work 30" :submit t :shell-buffer buffer :no-focus t)
        (emacs-agents-test-wait
         (lambda () (with-current-buffer buffer (string-match-p "Simulating work for 30 seconds" (buffer-string)))))
        (with-current-buffer buffer (agent-shell-interrupt t))
        (emacs-agents-test-wait
         (lambda () (with-current-buffer buffer (string-match-p "Simulation cancelled" (buffer-string)))))
        (emacs-agents-test-wait
         (lambda () (equal (emacs-agents-session-activity (emacs-agents-session id)) "input")))
        (should (equal conversation (emacs-agents-session-conversation (emacs-agents-session id))))))))
