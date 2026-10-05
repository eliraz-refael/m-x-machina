;;; mx-machina-acp-tests.el --- Real ACP transport tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'agent-shell)
(require 'agent-shell-mock-agent)
(require 'mx-machina-recovery)

(unless (boundp 'mx-machina-test-root)
  (load (expand-file-name "mx-machina-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(defun mx-machina-test-wait (predicate)
  "Service subprocesses for up to ten seconds until PREDICATE holds."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall predicate))))

(defun mx-machina-test-wait-rejected-resume (id)
  "Wait for ID's failed resume without debugging its expected guard error."
  ;; Emacs 29 debugs timer errors before its timer handler catches them.  Only
  ;; the two expected replacement guards are excluded; all other errors remain
  ;; visible to ERT, and callers still assert identity and actual wire requests.
  (let ((debug-ignored-errors
         (append '("^Resume failed: backend attempted a replacement;"
                   "^Unsupported resume: backend offers neither saved-session")
                 debug-ignored-errors)))
    (mx-machina-test-wait
     (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "failed")))))

(defmacro mx-machina-test-with-acp (&rest body)
  "Run BODY with a real agent-shell connected to the local fixture."
  (declare (indent 0) (debug t))
  `(mx-machina-test-with-store
     (let ((shell-maker-root-path user-emacs-directory)
           (agent-shell-mock-agent-acp-command
            (list "python3" (expand-file-name "test/fake-acp.py" mx-machina-test-root)
                  (expand-file-name "backend" temporary)))
           (agent-shell-agent-configs '(agent-shell-mock-agent-make-agent-config)))
       ,@body)))

(ert-deftest mx-machina-acp-round-trip-stop-and-resume ()
  (mx-machina-test-with-acp
    (let* ((id (mx-machina-create "Demo" repo "mock-agent"))
           (buffer (mx-machina-start id)))
      (mx-machina-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (let ((saved (mx-machina-session-conversation (mx-machina-session id)))
            (run (mx-machina-session-run (mx-machina-session id))))
        (should (stringp saved))
        (should-not (kill-buffer buffer))
        (agent-shell-insert :text "Hello" :submit t :shell-buffer buffer :no-focus t)
        (mx-machina-test-wait
         (lambda () (with-current-buffer buffer (string-match-p "Offline demo reply 1" (buffer-string)))))
        (mx-machina-stop id)
        (should (equal (mx-machina-session-status (mx-machina-session id)) "stopped"))
        (mx-machina-store-close)
        (setq buffer (mx-machina-start id))
        (mx-machina-test-wait
         (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
        (should (equal saved (mx-machina-session-conversation (mx-machina-session id))))
        (should-not (equal run (mx-machina-session-run (mx-machina-session id))))
        (agent-shell-insert :text "Again" :submit t :shell-buffer buffer :no-focus t)
        (mx-machina-test-wait
         (lambda () (with-current-buffer buffer (string-match-p "Offline demo reply 2" (buffer-string)))))))))

(ert-deftest mx-machina-acp-unsupported-resume-never-creates-replacement ()
  (mx-machina-test-with-acp
    (setq agent-shell-mock-agent-acp-command
          (append agent-shell-mock-agent-acp-command '("unsupported")))
    (let* ((id (mx-machina-create "Unsupported" repo "mock-agent"))
           (run (mx-machina--begin-run id)))
      (mx-machina--observe id run "stopped" "unknown" "saved-conversation")
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (mx-machina-retry id))
      (mx-machina-test-wait-rejected-resume id)
      (should (equal (mx-machina-session-conversation (mx-machina-session id)) "saved-conversation"))
      (should (eq (mx-machina-diagnostics--failure-kind (mx-machina-session-error (mx-machina-session id))) 'unsupported))
      (with-temp-buffer
        (insert-file-contents (expand-file-name "backend/requests.jsonl" temporary))
        (should-not (string-match-p "session/new" (buffer-string)))))))

(ert-deftest mx-machina-acp-missing-history-preserves-identity ()
  (mx-machina-test-with-acp
    (let* ((id (mx-machina-create "Missing" repo "mock-agent"))
           (run (mx-machina--begin-run id)))
      (mx-machina--observe id run "stopped" "unknown" "missing-conversation")
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (mx-machina-retry id))
      (mx-machina-test-wait-rejected-resume id)
      (should (equal (mx-machina-session-conversation (mx-machina-session id)) "missing-conversation"))
      (should (eq (mx-machina-diagnostics--failure-kind (mx-machina-session-error (mx-machina-session id))) 'resume))
      (with-temp-buffer
        (insert-file-contents (expand-file-name "backend/requests.jsonl" temporary))
        (should (string-match-p "session/load" (buffer-string)))
        (should-not (string-match-p "session/new" (buffer-string)))))))

(ert-deftest mx-machina-acp-resumes-in-a-new-emacs-process ()
  (mx-machina-test-with-store
    (let ((args (append
                 '("--batch" "-Q")
                 (apply #'append
                        (mapcar (lambda (library) (list "-L" (file-name-directory (locate-library library))))
                                '("mx-machina" "agent-shell" "acp" "shell-maker")))
                 (list "--eval" "(setq load-prefer-newer t)" "-l"
                       (expand-file-name "test/restart-phase.el" mx-machina-test-root) temporary))))
      (dolist (phase '("create" "restore"))
        (with-temp-buffer
          (let ((result (apply #'call-process (expand-file-name invocation-name invocation-directory)
                               nil '(t t) nil (append args (list phase)))))
            (unless (equal result 0) (ert-fail (buffer-string)))
            (should (string-match-p (if (equal phase "create") "CREATED" "RESTORED") (buffer-string)))))))))

(ert-deftest mx-machina-acp-offline-demo-is-reusable ()
  (mx-machina-test-with-acp
    (load (expand-file-name "examples/demo.el" mx-machina-test-root) nil t)
    (mx-machina-demo)
    (let ((id (mx-machina-session-id (car (mx-machina-sessions)))))
      (mx-machina-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (let ((saved (mx-machina-session-conversation (mx-machina-session id))))
        (mx-machina-stop id)
        (mx-machina-demo)
        (mx-machina-test-wait
         (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
        (should (= (length (mx-machina-sessions)) 1))
        (should (equal saved (mx-machina-session-conversation (mx-machina-session id))))))))

(ert-deftest mx-machina-acp-process-exit-retires-run ()
  (mx-machina-test-with-acp
    (let ((id (mx-machina-create "Exit" repo "mock-agent")))
      (mx-machina-start id)
      (mx-machina-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (let ((saved (mx-machina-session-conversation (mx-machina-session id))))
        (delete-process (mx-machina-backend-process (cdr (gethash id mx-machina--running))))
        (mx-machina--reconcile)
        (should-not (gethash id mx-machina--running))
        (should (equal (mx-machina-session-status (mx-machina-session id)) "exited"))
        (should (equal saved (mx-machina-session-conversation (mx-machina-session id))))))))

(ert-deftest mx-machina-acp-prompt-in-focus-keeps-layout-and-live-counts ()
  (mx-machina-test-with-acp
    (let ((id (mx-machina-create "Focused" repo "mock-agent")))
      (mx-machina-open id)
      (mx-machina-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (let ((buffer (current-buffer)))
        (should (string-match-p "1 ready" mx-machina--summary))
        (mx-machina-focus id)
        (agent-shell-insert :text "Work while I focus" :submit t :shell-buffer buffer :no-focus t)
        (mx-machina-test-wait
         (lambda () (with-current-buffer buffer (string-match-p "Offline demo reply 1" (buffer-string)))))
        (mx-machina-test-wait
         (lambda () (string-match-p "1 ready" mx-machina--summary)))
        (should (= (length (window-list)) 1))
        (should (eq (current-buffer) buffer))
        (mx-machina-focus)
        (should (get-buffer-window "*M-x Machina Sidebar*"))
        (should (eq (current-buffer) buffer))
        (should-not (window-parameter nil 'window-side))
        (mx-machina-close-view)
        (should (gethash id mx-machina--running))
        (should (buffer-live-p buffer))
        (should-not (get-buffer-window buffer))
        (mx-machina-stop id)
        (should (string-match-p "1 stopped" mx-machina--summary))))))

(ert-deftest mx-machina-acp-hidden-reply-is-unread-with-reported-model-header ()
  (mx-machina-test-with-acp
    (let* ((id (mx-machina-create "Harness" repo "mock-agent" "Work/Wix Panels"))
           (buffer (mx-machina-start id)))
      (mx-machina-test-wait
       (lambda () (equal (mx-machina-session-model (mx-machina-session id)) "Offline fixture")))
      (mx-machina)
      (agent-shell-insert :text "A reply while hidden" :submit t :shell-buffer buffer :no-focus t)
      (mx-machina-test-wait
       (lambda () (equal (mx-machina-session-activity (mx-machina-session id)) "input")))
      (should (mx-machina-unread-p (mx-machina-session id)))
      (with-current-buffer "*M-x Machina Sidebar*"
        (should (string-match-p "NEW" (buffer-string))))
      (mx-machina-open id)
      (with-current-buffer buffer
        (should (string-match-p "Harness" mx-machina--identity))
        (should (string-match-p "Offline fixture" mx-machina--identity))
        (should (string-match-p "Project: worktree" mx-machina--identity))
        (should (string-match-p "Branch: main" mx-machina--context))
        (should (string-match-p "Work/Wix Panels" mx-machina--context))
        (agent-shell--update-header-and-mode-line)
        (should (equal header-line-format '(:eval mx-machina--context))))
      (mx-machina-mark-read id)
      (mx-machina-stop id)
      (mx-machina-open id)
      (mx-machina-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (should-not (mx-machina-unread-p (mx-machina-session id))))))

(ert-deftest mx-machina-acp-simulated-work-finishes-and-can-be-cancelled ()
  (mx-machina-test-with-acp
    (let* ((id (mx-machina-create "Working demo" repo "mock-agent"))
           (buffer (mx-machina-start id)))
      (mx-machina-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (let ((conversation (mx-machina-session-conversation (mx-machina-session id))))
        (mx-machina)
        (agent-shell-insert :text "/work 1" :submit t :shell-buffer buffer :no-focus t)
        (mx-machina-test-wait
         (lambda () (with-current-buffer buffer (string-match-p "Simulating work for 1 seconds" (buffer-string)))))
        (should (equal (mx-machina-session-activity (mx-machina-session id)) "working"))
        (should (string-match-p "1 working" mx-machina--summary))
        (mx-machina-test-wait
         (lambda () (equal (mx-machina-session-activity (mx-machina-session id)) "input")))
        (should (mx-machina-unread-p (mx-machina-session id)))
        (agent-shell-insert :text "/work 30" :submit t :shell-buffer buffer :no-focus t)
        (mx-machina-test-wait
         (lambda () (with-current-buffer buffer (string-match-p "Simulating work for 30 seconds" (buffer-string)))))
        (with-current-buffer buffer (agent-shell-interrupt t))
        (mx-machina-test-wait
         (lambda () (with-current-buffer buffer (string-match-p "Simulation cancelled" (buffer-string)))))
        (mx-machina-test-wait
         (lambda () (equal (mx-machina-session-activity (mx-machina-session id)) "input")))
        (should (equal conversation (mx-machina-session-conversation (mx-machina-session id))))))))

(ert-deftest mx-machina-acp-recovery-rejected-history-never-replaces-session ()
  (mx-machina-test-with-acp
    (let* ((id (mx-machina-create "Relocated ACP" repo "mock-agent"))
           (new (expand-file-name "relocated" temporary)))
      (mx-machina-start id)
      (mx-machina-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (let* ((sid (mx-machina-session-conversation (mx-machina-session id)))
             (process (mx-machina-backend-process (cdr (gethash id mx-machina--running)))))
        (mx-machina-stop id)
        (mx-machina-test-wait (lambda () (not (process-live-p process))))
        (rename-file repo new)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (mx-machina-rebind-worktree id new))
        (mx-machina-start id)
        (mx-machina-test-wait-rejected-resume id)
        (should (equal sid (mx-machina-session-conversation (mx-machina-session id))))
        (with-temp-buffer
          (insert-file-contents (expand-file-name "backend/requests.jsonl" temporary))
          (let* ((rows (mapcar (lambda (line) (json-parse-string line :object-type 'alist))
                               (split-string (buffer-string) "\n" t)))
                 (loads (seq-filter (lambda (row) (equal (alist-get 'method row) "session/load")) rows)))
            (should (= 1 (seq-count (lambda (row) (equal (alist-get 'method row) "session/new")) rows)))
            (should (= 1 (length loads)))
            (should (equal sid (map-nested-elt (car loads) '(params sessionId))))
            (should (file-equal-p new (map-nested-elt (car loads) '(params cwd))))))))))

(ert-deftest mx-machina-acp-retry-authentication-failure-retains-id ()
  (mx-machina-test-with-acp
    (setq agent-shell-mock-agent-acp-command
          (append agent-shell-mock-agent-acp-command '("authentication-failure")))
    (let* ((id (mx-machina-create "Authentication" repo "mock-agent"))
           (run (mx-machina--begin-run id)))
      (mx-machina--observe id run "stopped" "unknown" "saved-id")
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (mx-machina-retry id))
      (mx-machina-test-wait-rejected-resume id)
      (should (equal (mx-machina-session-conversation (mx-machina-session id)) "saved-id"))
      (should (eq (mx-machina-diagnostics--failure-kind (mx-machina-session-error (mx-machina-session id))) 'authentication))
      (with-temp-buffer
        (insert-file-contents (expand-file-name "backend/requests.jsonl" temporary))
        (should-not (string-match-p "session/new\\|session/prompt" (buffer-string)))))))

(ert-deftest mx-machina-acp-session-title-refresh-and-minimal-resume ()
  (mx-machina-test-with-acp
    (let ((agent-shell-session-restore-verbosity 'minimal))
      (setq agent-shell-mock-agent-acp-command
            (append agent-shell-mock-agent-acp-command '("session-metadata")))
      (let* ((id (mx-machina-create "Metadata" repo "mock-agent"))
             (buffer (mx-machina-start id)))
        (mx-machina-test-wait
         (lambda () (with-current-buffer buffer
                      (equal (map-nested-elt agent-shell--state '(:session :title)) "Fixture title 0"))))
        (should (equal (mx-machina-session-status (mx-machina-session id)) "live"))
        (let ((saved (mx-machina-session-conversation (mx-machina-session id))))
          (agent-shell-insert :text "Hello" :submit t :shell-buffer buffer :no-focus t)
          (mx-machina-test-wait
           (lambda () (with-current-buffer buffer
                        (equal (map-nested-elt agent-shell--state '(:session :title)) "Fixture title 1"))))
          (should (equal (mx-machina-session-status (mx-machina-session id)) "live"))
          (mx-machina-stop id)
          (setq buffer (mx-machina-start id))
          (mx-machina-test-wait
           (lambda () (with-current-buffer buffer
                        (equal (map-nested-elt agent-shell--state '(:session :title)) "Fixture title 1"))))
          (should (equal (mx-machina-session-status (mx-machina-session id)) "live"))
          (should (equal (mx-machina-session-conversation (mx-machina-session id)) saved))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "backend/requests.jsonl" temporary))
            (let ((text (buffer-string)))
              (should (= 1 (how-many "session/new" (point-min) (point-max))))
              (should (= 1 (how-many "session/prompt" (point-min) (point-max))))
              (should (string-match-p "session/resume" text))
              (should (>= (how-many "session/list" (point-min) (point-max)) 3)))))))))

(ert-deftest mx-machina-acp-listing-after-failed-resume-cannot-replace ()
  (mx-machina-test-with-acp
    (setq agent-shell-mock-agent-acp-command
          (append agent-shell-mock-agent-acp-command '("session-metadata")))
    (let* ((agent-shell-session-restore-verbosity 'minimal)
           (id (mx-machina-create "Missing metadata history" repo "mock-agent"))
           (run (mx-machina--begin-run id)))
      (mx-machina--observe id run "stopped" "unknown" "missing-conversation")
      (mx-machina-start id)
      (mx-machina-test-wait-rejected-resume id)
      (should (equal (mx-machina-session-conversation (mx-machina-session id)) "missing-conversation"))
      (with-temp-buffer
        (insert-file-contents (expand-file-name "backend/requests.jsonl" temporary))
        (should (string-match-p "session/list" (buffer-string)))
        (should-not (string-match-p "session/new" (buffer-string)))))))

(ert-deftest mx-machina-acp-stopped-buffer-cannot-respawn-client ()
  (mx-machina-test-with-acp
    (let* ((id (mx-machina-create "Stopped" repo "mock-agent"))
           (buffer (mx-machina-start id)))
      (mx-machina-test-wait (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (let* ((client (buffer-local-value 'agent-shell--state buffer))
             (client (map-elt client :client))
             (saved (mx-machina-session-conversation (mx-machina-session id))))
        (mx-machina-stop id)
        (should-error
         (acp-send-request :client client :buffer buffer
                           :request `((:method . "session/prompt")
                                      (:params . ((sessionId . ,saved) (prompt . []))))))
        (should-not (map-elt client :process))
        (should-not (gethash id mx-machina--running))
        (should (equal (mx-machina-session-conversation (mx-machina-session id)) saved))
        (mx-machina-start id)
        (mx-machina-test-wait (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
        (should (equal (mx-machina-session-conversation (mx-machina-session id)) saved))))))
