;;; emacs-agents-messaging-integration-tests.el --- Real messaging transports -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(load (expand-file-name "emacs-agents-messaging-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(load (expand-file-name "emacs-agents-acp-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(load (expand-file-name "emacs-agents-vterm-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(ert-deftest emacs-agents-messaging-acp-draft-and-correlated-reply ()
  (emacs-agents-test-with-acp
    (emacs-agents-test-with-messaging
      (let* ((id (emacs-agents-create "Receiver" repo "mock-agent"))
             (buffer (emacs-agents-start id)))
        (emacs-agents-test-wait (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
        (let ((r (emacs-agents-messaging-send id "Hello from another agent"))
              (window (selected-window)))
          (with-current-buffer buffer (goto-char (point-max)) (insert "unsent draft"))
          (emacs-agents-messaging--tick)
          (should (equal (alist-get 'status r) "queued"))
          (should (string-match-p "draft" (alist-get 'hold r)))
          (with-current-buffer buffer (delete-region (agent-shell--prompt-input-start) (point-max)))
          (emacs-agents-messaging--tick)
          (emacs-agents-test-wait (lambda () (equal (alist-get 'status r) "completed")))
          (should (string-match-p "Offline demo reply 1" (alist-get 'response r)))
          (should (eq (selected-window) window))
          (should (emacs-agents-unread-p (emacs-agents-session id)))
          (should (= (file-modes (expand-file-name (concat (alist-get 'id r) ".json") (emacs-agents-messaging--directory))) #o600)))))))

(defun emacs-agents-messaging-test-terminal (profile repo)
  "Check PROFILE's real terminal path, queue and hook reply correlation."
  (let* ((id (emacs-agents-create "Receiver" repo profile))
         (buffer (emacs-agents-start id)))
    (emacs-agents-eat-test-wait (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
    (let ((r (emacs-agents-messaging-send id "First message: λ and \"quoted\"\nsecond line")))
      (emacs-agents-open id)
      (emacs-agents-messaging--tick)
      (should (equal (alist-get 'status r) "queued"))
      (should (string-match-p "visible" (alist-get 'hold r)))
      (emacs-agents-close-view)
      (emacs-agents-messaging--tick)
      (emacs-agents-eat-test-wait (lambda () (equal (alist-get 'status r) "completed")))
      (should (equal (alist-get 'response r) "Terminal reply 1"))
      (should (emacs-agents-unread-p (emacs-agents-session id)))
      (let* ((transport (cdr (gethash id emacs-agents--running)))
             (r2 (emacs-agents-messaging-send id "Queued behind human work")))
        (with-current-buffer buffer (setq emacs-agents-messaging--draft t))
        (emacs-agents-messaging--tick)
        (should (equal (alist-get 'status r2) "queued"))
        (should (string-match-p "draft" (alist-get 'hold r2)))
        (process-send-string (get-buffer-process buffer) "/ask\n")
        (emacs-agents-eat-test-wait (lambda () (equal (emacs-agents-session-activity (emacs-agents-session id)) "approval")))
        (emacs-agents-messaging--tick)
        (should (equal (alist-get 'status r2) "queued"))
        (process-send-string (get-buffer-process buffer) "/approve\n")
        (emacs-agents-eat-test-wait (lambda () (equal (emacs-agents-session-activity (emacs-agents-session id)) "input")))
        (emacs-agents-messaging--tick)
        (emacs-agents-eat-test-wait (lambda () (equal (alist-get 'status r2) "completed")))
        (should (equal (alist-get 'response r2) "Terminal reply 3"))
        (should-not (file-exists-p (emacs-agents-messaging--marker transport)))
        (emacs-agents-stop id)))))

(ert-deftest emacs-agents-messaging-eat-reply-queue-and-permission ()
  (emacs-agents-test-with-eat
    (emacs-agents-test-with-messaging
      (emacs-agents-messaging-test-terminal "test-eat" repo))))

(ert-deftest emacs-agents-messaging-vterm-reply-queue-and-permission ()
  (emacs-agents-test-with-eat
    (let ((emacs-agents-vterm-profiles 'inherit))
      (emacs-agents-test-with-messaging
        (emacs-agents-messaging-test-terminal "test-eat-vterm" repo)))))

(ert-deftest emacs-agents-messaging-mismatched-prompt-and-run-never-return-reply ()
  (emacs-agents-test-with-eat
    (emacs-agents-test-with-messaging
      (let* ((id (emacs-agents-create "Receiver" repo "test-eat"))
             (buffer (emacs-agents-start id)))
        (emacs-agents-eat-test-wait (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
        (let ((r (emacs-agents-messaging-send id "Will not send"))
              (transport (cdr (gethash id emacs-agents--running))))
          (cl-letf (((symbol-function 'emacs-agents-messaging--deliver) #'ignore)) (emacs-agents-messaging--tick))
          (emacs-agents-messaging--event transport 'prompt '(:hash "different prompt"))
          (emacs-agents-messaging--event transport 'turn-ended '(:text "Other user's reply"))
          (should (equal (alist-get 'status r) "failed"))
          (should-not (alist-get 'response r))
          (should (buffer-local-value 'emacs-agents-messaging--draft buffer))
          (with-current-buffer buffer (setq emacs-agents-messaging--draft nil))
          (let ((r2 (emacs-agents-messaging-send id "Old run")))
            (cl-letf (((symbol-function 'emacs-agents-messaging--deliver) #'ignore)) (emacs-agents-messaging--tick))
            (emacs-agents-stop id)
            (emacs-agents-messaging--tick)
            (should (equal (alist-get 'status r2) "failed")))
          (should (buffer-live-p buffer)))))))

(defmacro emacs-agents-test-with-message-server (&rest body)
  "Run BODY with a server whose hooks cannot escape this temporary fixture."
  (declare (indent 0) (debug t))
  `(let* ((server-name "message-fixture")
          (server-socket-dir (expand-file-name "socket/" temporary))
          (server-process nil) (server-clients nil) (server-mode nil)
          (kill-emacs-hook nil) (kill-emacs-query-functions nil)
          (delete-frame-functions nil) (suspend-tty-functions nil)
          (global-minor-modes nil))
     (unwind-protect
         (progn (server-start) ,@body)
       (when server-process (delete-process server-process)))))

(ert-deftest emacs-agents-messaging-cli-end-to-end ()
  (emacs-agents-test-with-acp
    (emacs-agents-test-with-message-server
      (emacs-agents-test-with-messaging
        (setq emacs-agents-messaging--timer (run-at-time 0.1 0.1 #'emacs-agents-messaging--tick))
        (let* ((id (emacs-agents-create "CLI recipient" repo "mock-agent"))
               (_buffer (emacs-agents-start id))
               (output (generate-new-buffer " *message-cli-output*")))
          (unwind-protect
              (progn
                (emacs-agents-test-wait (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
                (let ((process (make-process
                                :name "message-cli" :buffer output :connection-type 'pipe :noquery t
                                :command (list "python3" emacs-agents-messaging--script "--socket"
                                               (expand-file-name server-name server-socket-dir)
                                               "send" id "Hello λ \"quotes\" $(no shell)" "--wait" "--timeout" "8"))))
                  (emacs-agents-test-wait (lambda () (not (process-live-p process))))
                  (should (= (process-exit-status process) 0))
                  (with-current-buffer output
                    (goto-char (point-min))
                    (re-search-forward "^{")
                    (backward-char)
                    (let ((response (json-parse-buffer :object-type 'alist)))
                      (should (equal (alist-get 'status response) "completed"))
                      (should (string-match-p "Offline demo reply 1" (alist-get 'response response)))))))
            (kill-buffer output)))))))

(defun emacs-agents-messaging-test-peer (without-identity)
  "Exercise CLI identity and exchange, optionally WITHOUT-IDENTITY in the environment."
  (emacs-agents-test-with-eat
    (emacs-agents-test-with-message-server
      (emacs-agents-test-with-messaging
        (setq emacs-agents-messaging--timer (run-at-time 0.1 0.1 #'emacs-agents-messaging--tick))
        (let* ((a (emacs-agents-create "Sender" repo "test-eat"))
               (b (emacs-agents-create "Receiver" repo "test-eat"))
               (source (emacs-agents-start a)))
          (emacs-agents-start b)
          (emacs-agents-eat-test-wait (lambda () (and (equal (emacs-agents-session-status (emacs-agents-session a)) "live")
                                                     (equal (emacs-agents-session-status (emacs-agents-session b)) "live"))))
          (process-send-string (get-buffer-process source) (concat (if without-identity "/peer-no-identity " "/peer ") b "\n"))
          (emacs-agents-eat-test-wait
           (lambda () (with-current-buffer source (string-match-p "Peer replied: Terminal reply 1" (buffer-string)))))
          (should (with-current-buffer source (string-match-p (concat "Identity: " a) (buffer-string))))
          (let ((record (car (hash-table-values emacs-agents-messaging--records))))
            (should (equal (alist-get 'sender record) a))
            (should (equal (alist-get 'target record) b))
            (should (equal (alist-get 'status record) "completed"))))))))

(ert-deftest emacs-agents-messaging-socket-failure-leaves-no-shutdown-hook ()
  (emacs-agents-test-with-store
    (let ((hooks (copy-sequence kill-emacs-hook)))
      (cl-letf (((symbol-function 'make-network-process)
                 (lambda (&rest _) (signal 'file-error '("Cannot bind test socket")))))
        (should-error (emacs-agents-test-with-message-server t)))
      (should (equal hooks kill-emacs-hook)))))

(ert-deftest emacs-agents-messaging-cli-agent-to-agent ()
  (emacs-agents-messaging-test-peer nil))

(ert-deftest emacs-agents-messaging-cli-existing-agent-identity ()
  (emacs-agents-messaging-test-peer t))

(ert-deftest emacs-agents-messaging-acp-launch-environment-is-per-agent ()
  (emacs-agents-test-with-acp
    (emacs-agents-test-with-messaging
      (let* ((config (agent-shell-mock-agent-make-agent-config))
             (maker (map-elt config :client-maker))
             (account (expand-file-name "fixture-account" temporary)))
        (setf (map-elt config :client-maker)
              (lambda (buffer)
                (let ((client (funcall maker buffer)))
                  (setf (map-elt client :environment-variables)
                        (list (concat "CLAUDE_CONFIG_DIR=" account)))
                  client)))
        (let* ((agent-shell-agent-configs (list config))
               (original-maker (map-elt config :client-maker))
               (a (emacs-agents-create "A" repo "mock-agent"))
               (b (emacs-agents-create "B" repo "mock-agent")))
          (emacs-agents-start a)
          (emacs-agents-start b)
          (dolist (id (list a b))
            (emacs-agents-test-wait
             (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
            (let* ((process (emacs-agents-backend-process (cdr (gethash id emacs-agents--running))))
                   (file (expand-file-name (format "backend/environment-%s.log" (process-id process)) temporary))
                   (data (with-temp-buffer (insert-file-contents file)
                                           (json-parse-buffer :object-type 'alist))))
              (should (equal (alist-get 'EMACS_AGENTS_ID data) id))
              (should (equal (alist-get 'EMACS_AGENTS_CLI data) emacs-agents-messaging--script))
              (should (equal (alist-get 'EMACS_AGENTS_SOCKET data) (expand-file-name server-name server-socket-dir)))
              (should (equal (alist-get 'CLAUDE_CONFIG_DIR data) account))))
          (should (eq original-maker (map-elt config :client-maker))))))))

(ert-deftest emacs-agents-messaging-legacy-cli-retains-process-identity ()
  ;; Old processes keep the legacy path in their environment.  Its launcher
  ;; must preserve the caller's ancestry so automatic sender attribution works.
  (let ((emacs-agents-messaging--script
         (expand-file-name "scripts/emacs-agents" emacs-agents-test-root)))
    (emacs-agents-messaging-test-peer t)))
