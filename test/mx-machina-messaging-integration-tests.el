;;; mx-machina-messaging-integration-tests.el --- Real messaging transports -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(load (expand-file-name "mx-machina-messaging-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(load (expand-file-name "mx-machina-acp-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(load (expand-file-name "mx-machina-vterm-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(ert-deftest mx-machina-messaging-acp-draft-and-correlated-reply ()
  (mx-machina-test-with-acp
    (mx-machina-test-with-messaging
      (let* ((id (mx-machina-create "Receiver" repo "mock-agent"))
             (buffer (mx-machina-start id)))
        (mx-machina-test-wait (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
        (let ((r (mx-machina-messaging-send id "Hello from another agent"))
              (window (selected-window)))
          (with-current-buffer buffer (goto-char (point-max)) (insert "unsent draft"))
          (mx-machina-messaging--tick)
          (should (equal (alist-get 'status r) "queued"))
          (should (string-match-p "draft" (alist-get 'hold r)))
          (with-current-buffer buffer (delete-region (agent-shell--prompt-input-start) (point-max)))
          (mx-machina-messaging--tick)
          (mx-machina-test-wait (lambda () (equal (alist-get 'status r) "completed")))
          (should (string-match-p "Offline demo reply 1" (alist-get 'response r)))
          (should (eq (selected-window) window))
          (should (mx-machina-unread-p (mx-machina-session id)))
          (should (= (file-modes (expand-file-name (concat (alist-get 'id r) ".json") (mx-machina-messaging--directory))) #o600)))))))

(defun mx-machina-messaging-test-terminal (profile repo)
  "Check PROFILE's real terminal path, queue and hook reply correlation."
  (let* ((id (mx-machina-create "Receiver" repo profile))
         (buffer (mx-machina-start id)))
    (mx-machina-eat-test-wait (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
    (let ((r (mx-machina-messaging-send id "First message: λ and \"quoted\"\nsecond line")))
      (mx-machina-open id)
      (mx-machina-messaging--tick)
      (should (equal (alist-get 'status r) "queued"))
      (should (string-match-p "visible" (alist-get 'hold r)))
      (mx-machina-close-view)
      (mx-machina-messaging--tick)
      (mx-machina-eat-test-wait (lambda () (equal (alist-get 'status r) "completed")))
      (should (equal (alist-get 'response r) "Terminal reply 1"))
      (should (mx-machina-unread-p (mx-machina-session id)))
      (let* ((transport (cdr (gethash id mx-machina--running)))
             (r2 (mx-machina-messaging-send id "Queued behind human work")))
        (with-current-buffer buffer (setq mx-machina-messaging--draft t))
        (mx-machina-messaging--tick)
        (should (equal (alist-get 'status r2) "queued"))
        (should (string-match-p "draft" (alist-get 'hold r2)))
        (process-send-string (get-buffer-process buffer) "/ask\n")
        (mx-machina-eat-test-wait (lambda () (equal (mx-machina-session-activity (mx-machina-session id)) "approval")))
        (mx-machina-messaging--tick)
        (should (equal (alist-get 'status r2) "queued"))
        (process-send-string (get-buffer-process buffer) "/approve\n")
        (mx-machina-eat-test-wait (lambda () (equal (mx-machina-session-activity (mx-machina-session id)) "input")))
        (mx-machina-messaging--tick)
        (mx-machina-eat-test-wait (lambda () (equal (alist-get 'status r2) "completed")))
        (should (equal (alist-get 'response r2) "Terminal reply 3"))
        (should-not (file-exists-p (mx-machina-messaging--marker transport)))
        (mx-machina-stop id)))))

(ert-deftest mx-machina-messaging-eat-reply-queue-and-permission ()
  (mx-machina-test-with-eat
    (mx-machina-test-with-messaging
      (mx-machina-messaging-test-terminal "test-eat" repo))))

(ert-deftest mx-machina-messaging-vterm-reply-queue-and-permission ()
  (mx-machina-test-with-eat
    (let ((mx-machina-vterm-profiles 'inherit))
      (mx-machina-test-with-messaging
        (mx-machina-messaging-test-terminal "test-eat-vterm" repo)))))

(ert-deftest mx-machina-messaging-mismatched-prompt-and-run-never-return-reply ()
  (mx-machina-test-with-eat
    (mx-machina-test-with-messaging
      (let* ((id (mx-machina-create "Receiver" repo "test-eat"))
             (buffer (mx-machina-start id)))
        (mx-machina-eat-test-wait (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
        (let ((r (mx-machina-messaging-send id "Will not send"))
              (transport (cdr (gethash id mx-machina--running))))
          (cl-letf (((symbol-function 'mx-machina-messaging--deliver) #'ignore)) (mx-machina-messaging--tick))
          (mx-machina-messaging--event transport 'prompt '(:hash "different prompt"))
          (mx-machina-messaging--event transport 'turn-ended '(:text "Other user's reply"))
          (should (equal (alist-get 'status r) "failed"))
          (should-not (alist-get 'response r))
          (should (buffer-local-value 'mx-machina-messaging--draft buffer))
          (with-current-buffer buffer (setq mx-machina-messaging--draft nil))
          (let ((r2 (mx-machina-messaging-send id "Old run")))
            (cl-letf (((symbol-function 'mx-machina-messaging--deliver) #'ignore)) (mx-machina-messaging--tick))
            (mx-machina-stop id)
            (mx-machina-messaging--tick)
            (should (equal (alist-get 'status r2) "failed")))
          (should (buffer-live-p buffer)))))))

(defmacro mx-machina-test-with-message-server (&rest body)
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

(ert-deftest mx-machina-messaging-cli-end-to-end ()
  (mx-machina-test-with-acp
    (mx-machina-test-with-message-server
      (mx-machina-test-with-messaging
        (setq mx-machina-messaging--timer (run-at-time 0.1 0.1 #'mx-machina-messaging--tick))
        (let* ((id (mx-machina-create "CLI recipient" repo "mock-agent"))
               (_buffer (mx-machina-start id))
               (output (generate-new-buffer " *message-cli-output*")))
          (unwind-protect
              (progn
                (mx-machina-test-wait (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
                (let ((process (make-process
                                :name "message-cli" :buffer output :connection-type 'pipe :noquery t
                                :command (list "python3" mx-machina-messaging--script "--socket"
                                               (expand-file-name server-name server-socket-dir)
                                               "send" id "Hello λ \"quotes\" $(no shell)" "--wait" "--timeout" "8"))))
                  (mx-machina-test-wait (lambda () (not (process-live-p process))))
                  (should (= (process-exit-status process) 0))
                  (with-current-buffer output
                    (goto-char (point-min))
                    (re-search-forward "^{")
                    (backward-char)
                    (let ((response (json-parse-buffer :object-type 'alist)))
                      (should (equal (alist-get 'status response) "completed"))
                      (should (string-match-p "Offline demo reply 1" (alist-get 'response response)))))))
            (kill-buffer output)))))))

(defun mx-machina-messaging-test-peer (without-identity)
  "Exercise CLI identity and exchange, optionally WITHOUT-IDENTITY in the environment."
  (mx-machina-test-with-eat
    (mx-machina-test-with-message-server
      (mx-machina-test-with-messaging
        (setq mx-machina-messaging--timer (run-at-time 0.1 0.1 #'mx-machina-messaging--tick))
        (let* ((a (mx-machina-create "Sender" repo "test-eat"))
               (b (mx-machina-create "Receiver" repo "test-eat"))
               (source (mx-machina-start a)))
          (mx-machina-start b)
          (mx-machina-eat-test-wait (lambda () (and (equal (mx-machina-session-status (mx-machina-session a)) "live")
                                                     (equal (mx-machina-session-status (mx-machina-session b)) "live"))))
          (process-send-string (get-buffer-process source) (concat (if without-identity "/peer-no-identity " "/peer ") b "\n"))
          (mx-machina-eat-test-wait
           (lambda () (with-current-buffer source (string-match-p "Peer replied: Terminal reply 1" (buffer-string)))))
          (should (with-current-buffer source (string-match-p (concat "Identity: " a) (buffer-string))))
          (let ((record (car (hash-table-values mx-machina-messaging--records))))
            (should (equal (alist-get 'sender record) a))
            (should (equal (alist-get 'target record) b))
            (should (equal (alist-get 'status record) "completed"))))))))

(ert-deftest mx-machina-messaging-socket-failure-leaves-no-shutdown-hook ()
  (mx-machina-test-with-store
    (let ((hooks (copy-sequence kill-emacs-hook)))
      (cl-letf (((symbol-function 'make-network-process)
                 (lambda (&rest _) (signal 'file-error '("Cannot bind test socket")))))
        (should-error (mx-machina-test-with-message-server t)))
      (should (equal hooks kill-emacs-hook)))))

(ert-deftest mx-machina-messaging-cli-agent-to-agent ()
  (mx-machina-messaging-test-peer nil))

(ert-deftest mx-machina-messaging-cli-existing-agent-identity ()
  (mx-machina-messaging-test-peer t))

(ert-deftest mx-machina-messaging-acp-launch-environment-is-per-agent ()
  (mx-machina-test-with-acp
    (mx-machina-test-with-messaging
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
               (a (mx-machina-create "A" repo "mock-agent"))
               (b (mx-machina-create "B" repo "mock-agent")))
          (mx-machina-start a)
          (mx-machina-start b)
          (dolist (id (list a b))
            (mx-machina-test-wait
             (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
            (let* ((process (mx-machina-backend-process (cdr (gethash id mx-machina--running))))
                   (file (expand-file-name (format "backend/environment-%s.log" (process-id process)) temporary))
                   (data (with-temp-buffer (insert-file-contents file)
                                           (json-parse-buffer :object-type 'alist))))
              (should (equal (alist-get 'EMACS_AGENTS_ID data) id))
              (should (equal (alist-get 'EMACS_AGENTS_CLI data) mx-machina-messaging--script))
              (should (equal (alist-get 'EMACS_AGENTS_SOCKET data) (expand-file-name server-name server-socket-dir)))
              (should (equal (alist-get 'CLAUDE_CONFIG_DIR data) account))))
          (should (eq original-maker (map-elt config :client-maker))))))))

(ert-deftest mx-machina-messaging-legacy-cli-retains-process-identity ()
  ;; Old processes keep the legacy path in their environment.  Its launcher
  ;; must preserve the caller's ancestry so automatic sender attribution works.
  (let ((mx-machina-messaging--script
         (expand-file-name "scripts/emacs-agents" mx-machina-test-root)))
    (mx-machina-messaging-test-peer t)))

(ert-deftest mx-machina-messaging-cli-reaches-pre-rename-server ()
  (mx-machina-test-with-store
    (mx-machina-test-with-message-server
      (mx-machina-test-with-messaging
        ;; Model an Emacs that still exposes only the old RPC until restart.
        (cl-letf (((symbol-function 'emacs-agents-messaging-rpc)
                   (symbol-function 'mx-machina-messaging-rpc))
                  ((symbol-function 'mx-machina-messaging-rpc) nil))
          (let ((output (generate-new-buffer " *legacy-message-cli*")))
            (unwind-protect
                (let ((process (make-process
                                :name "legacy-message-cli" :buffer output
                                :connection-type 'pipe :noquery t
                                :command (list "python3" mx-machina-messaging--script "--socket"
                                               (expand-file-name server-name server-socket-dir) "list"))))
                  (mx-machina-test-wait (lambda () (not (process-live-p process))))
                  (should (= (process-exit-status process) 0))
                  (with-current-buffer output
                    (goto-char (point-min))
                    (should (equal (json-parse-buffer :array-type 'list) nil))))
              (kill-buffer output))))))))
