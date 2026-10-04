;;; emacs-agents-messaging.el --- Correlated local agent messages -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Opt-in delivery through existing transports. No background launches or replay.
;;; Code:
(require 'emacs-agents)
(require 'json)
(require 'server)
(defvar eat-terminal)
(declare-function eat-term-send-string-as-yank "eat")
(declare-function eat-term-send-string "eat")
(declare-function vterm-send-string "vterm")
(declare-function vterm-send-return "vterm")
(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell--prompt-input-start "agent-shell")
(defvar emacs-agents-messaging-mode)
(defvar emacs-agents-messaging--records (make-hash-table :test #'equal))
(defvar emacs-agents-messaging--timer nil)
(defvar emacs-agents-messaging--sending nil)
(defvar emacs-agents-messaging--ticking nil)
(defvar-local emacs-agents-messaging--draft t)
(defvar-local emacs-agents-messaging--input-generation 0)
(defvar-local emacs-agents-messaging--submitted-generation nil)
(defvar emacs-agents-messaging--last-prune 0)
(defcustom emacs-agents-messaging-retention-days 7
  "Days to retain completed CLI messages and their idempotency keys."
  :type 'natnum :group 'emacs-agents)
(defconst emacs-agents-messaging--script
  (expand-file-name "../scripts/mxm" (file-name-directory (or load-file-name buffer-file-name))))
(defconst emacs-agents-messaging--pending '("queued" "sending" "working"))

(defun emacs-agents-messaging--directory ()
  "Return this registry's private message directory."
  (expand-file-name "messages/" emacs-agents-directory))

(defun emacs-agents-messaging--save (record)
  "Atomically persist RECORD before allowing any terminal side effect."
  (let* ((directory (emacs-agents-messaging--directory))
         (file (expand-file-name (concat (alist-get 'id record) ".json") directory))
         (temporary (make-temp-file (expand-file-name ".write-" directory))))
    (unwind-protect
        (progn
          (set-file-modes temporary #o600)
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file temporary (insert (json-encode record))))
          (rename-file temporary file t)
          (puthash (alist-get 'id record) record emacs-agents-messaging--records))
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun emacs-agents-messaging--marker (transport)
  "Return TRANSPORT's hook correlation marker, when it is a terminal."
  (when (emacs-agents--terminal-transport-p transport)
    (with-current-buffer (emacs-agents-transport-buffer transport)
      (expand-file-name "message-request" emacs-agents-claude--run-directory))))

(defun emacs-agents-messaging--finish (record status &optional response error)
  "Save terminal STATUS and optional RESPONSE or ERROR for RECORD."
  (when (and (equal status "failed") (member (alist-get 'status record) '("sending" "working")))
    (when-let* ((entry (gethash (alist-get 'target record) emacs-agents--running)))
      (when (and (equal (car entry) (alist-get 'run record))
                 (emacs-agents--terminal-transport-p (cdr entry)))
        (with-current-buffer (emacs-agents-transport-buffer (cdr entry))
          (setq emacs-agents-messaging--draft t)))))
  (setf (alist-get 'status record) status
        (alist-get 'response record) response
        (alist-get 'error record) error)
  (emacs-agents-messaging--save record)
  (when-let* ((entry (gethash (alist-get 'target record) emacs-agents--running))
              (file (emacs-agents-messaging--marker (cdr entry))))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (when (equal (buffer-string) (alist-get 'id record)) (delete-file file))))))

(defun emacs-agents-messaging--resolve (target)
  "Resolve TARGET as an exact ID or unambiguous full folder/name."
  (or (emacs-agents-session target t)
      (let ((matches (seq-filter
                      (lambda (s) (equal target (emacs-agents-messaging--name s)))
                      (emacs-agents-sessions))))
        (unless (= (length matches) 1)
          (user-error "Use an exact agent ID or unique full folder/name (see CLI list)"))
        (car matches))))

(defun emacs-agents-messaging--name (session)
  "Return SESSION's full logical name."
  (string-join (seq-remove #'string-empty-p
                           (list (emacs-agents-session-folder session) (emacs-agents-session-name session))) "/"))

(defun emacs-agents-messaging--cycle-p (sender target &optional seen)
  "Return non-nil if adding SENDER to TARGET would create a pending cycle."
  (or (equal sender target)
      (and (not (member target seen))
           (seq-some (lambda (r)
                       (and (member (alist-get 'status r) emacs-agents-messaging--pending)
                            (equal (alist-get 'sender r) target)
                            (emacs-agents-messaging--cycle-p sender (alist-get 'target r) (cons target seen))))
                     (hash-table-values emacs-agents-messaging--records)))))

(defun emacs-agents-messaging-send (target text &optional sender request)
  "Queue TEXT to TARGET, with optional SENDER and idempotent REQUEST ID."
  (unless emacs-agents-messaging-mode (user-error "Enable emacs-agents-messaging-mode first"))
  (unless (and (stringp text) (not (string-empty-p (string-trim text))) (<= (string-bytes text) 16384))
    (user-error "Use a nonempty message of at most 16 KiB"))
  (setq request (or request (emacs-agents-claude--uuid)))
  (unless (and (stringp request) (string-match-p "\\`[a-zA-Z0-9-]\\{8,80\\}\\'" request))
    (user-error "Invalid request ID"))
  (let* ((session (emacs-agents-messaging--resolve target))
         (id (emacs-agents-session-id session))
         (source (when sender (emacs-agents-messaging--resolve sender)))
         (source-id (and source (emacs-agents-session-id source)))
         (existing (gethash request emacs-agents-messaging--records)))
    (if existing
        (progn
          (unless (and (equal text (alist-get 'text existing))
                       (equal id (alist-get 'target existing)) (equal source-id (alist-get 'sender existing)))
            (user-error "Request ID already belongs to a different message"))
          existing)
      (when (emacs-agents-archived-p session) (user-error "Restore the recipient first"))
      (unless (gethash id emacs-agents--running) (user-error "Start the recipient first; messaging does not launch agents"))
      (when (and source-id (emacs-agents-messaging--cycle-p source-id id))
        (user-error "This message would create a pending request cycle"))
      (when (>= (seq-count (lambda (r) (member (alist-get 'status r) emacs-agents-messaging--pending))
                           (hash-table-values emacs-agents-messaging--records)) 100)
        (user-error "Message queue is full"))
      (let* ((payload (format "[M-x Machina request %s from %s] Reply to this message normally; your completed reply is returned to the caller. Message (JSON string): %s"
                              request (if source (emacs-agents-messaging--name source) "user CLI") (json-encode text)))
             (record (copy-tree `((id . ,request) (target . ,id) (sender . ,source-id)
                       (text . ,text) (prompt . ,payload) (status . "queued")
                       (hold . nil) (run . nil) (sent . nil)
                       (created . ,(float-time)) (response . nil) (error . nil)))))
        (emacs-agents-messaging--save record)
        record))))

(defun emacs-agents-messaging--input (&rest _)
  "Conservatively remember terminal input until its prompt is acknowledged."
  (when (and emacs-agents-messaging-mode (not emacs-agents-messaging--sending)
             emacs-agents--managed-id)
    (setq emacs-agents-messaging--draft t)
    (cl-incf emacs-agents-messaging--input-generation)))

(defun emacs-agents-messaging--eat-input (_terminal input)
  "Track INPUT and recognize submission without clearing a later draft."
  (emacs-agents-messaging--input)
  (when (and emacs-agents-messaging-mode emacs-agents--managed-id
             (not emacs-agents-messaging--sending) (member input '("\r" "\n")))
    (setq emacs-agents-messaging--submitted-generation emacs-agents-messaging--input-generation)))

(defun emacs-agents-messaging--vterm-key (key &rest _)
  "Track KEY and remember the generation submitted by Return."
  (emacs-agents-messaging--input)
  (when (and emacs-agents-messaging-mode emacs-agents--managed-id
             (not emacs-agents-messaging--sending) (equal key "<return>"))
    (setq emacs-agents-messaging--submitted-generation emacs-agents-messaging--input-generation)))

(defun emacs-agents-messaging--prune ()
  "Expire completed mailbox records while retaining all pending requests."
  (when (> (- (float-time) emacs-agents-messaging--last-prune) 60)
    (setq emacs-agents-messaging--last-prune (float-time))
    (let ((cutoff (- (float-time) (* 86400 (max 1 emacs-agents-messaging-retention-days)))))
      (dolist (record (hash-table-values emacs-agents-messaging--records))
        (when (and (not (member (alist-get 'status record) emacs-agents-messaging--pending))
                   (< (alist-get 'created record) cutoff))
          (delete-file (expand-file-name (concat (alist-get 'id record) ".json") (emacs-agents-messaging--directory)))
          (remhash (alist-get 'id record) emacs-agents-messaging--records))))))

(defun emacs-agents-messaging-ready (id)
  "Allow delivery to ID after the user confirms its terminal prompt is empty."
  (interactive (list (emacs-agents--read-id)))
  (let* ((entry (gethash id emacs-agents--running))
         (buffer (and entry (emacs-agents-transport-buffer (cdr entry)))))
    (unless (buffer-live-p buffer) (user-error "Start the agent first"))
    (unless (yes-or-no-p "Is the agent's input prompt empty, with no draft or dialog? ")
      (user-error "Delivery remains held"))
    (with-current-buffer buffer (setq emacs-agents-messaging--draft nil))))

(defun emacs-agents-messaging--hold (session transport)
  "Explain why SESSION and TRANSPORT cannot receive a new message yet."
  (let ((buffer (emacs-agents-transport-buffer transport)))
    (cond
     ((or (not (emacs-agents-transport-ready transport))
          (not (equal (emacs-agents-session-status session) "live"))
          (not (equal (emacs-agents-session-activity session) "input"))) "Agent is not ready (busy, starting or waiting for approval)")
     ((not (buffer-live-p buffer)) "Conversation buffer is unavailable")
     ((and (emacs-agents--terminal-transport-p transport)
           (buffer-local-value 'emacs-agents-claude--turn-active buffer)) "Previous terminal turn is still active")
     ((get-buffer-window buffer t) "Conversation is visible; hide it to allow delivery")
     (t
      (with-current-buffer buffer
        (if (emacs-agents--terminal-transport-p transport)
            (when emacs-agents-messaging--draft "Terminal may contain a draft; submit it or use M-x emacs-agents-messaging-ready")
          (let ((start (agent-shell--prompt-input-start)))
            (when (or (not start) (not (string-empty-p (string-trim (buffer-substring-no-properties start (point-max))))))
              "Conversation contains a draft or has no prompt"))))))))

(defun emacs-agents-messaging--deliver (record transport)
  "Submit RECORD through TRANSPORT without taking keyboard focus."
  (let ((prompt (alist-get 'prompt record))
        (emacs-agents-messaging--sending t))
    (with-current-buffer (emacs-agents-transport-buffer transport)
      (pcase emacs-agents--backend-kind
        ('eat (eat-term-send-string-as-yank eat-terminal (list prompt))
              (eat-term-send-string eat-terminal "\r"))
        ('vterm (vterm-send-string prompt t) (vterm-send-return))
        (_ (agent-shell-insert :text prompt :submit t :no-focus t :shell-buffer (current-buffer)))))))

(defun emacs-agents-messaging--tick-1 ()
  "Advance the queue, never retrying an uncertain submission."
  (when (and emacs-agents-messaging-mode (not emacs-agents-messaging--ticking))
    (emacs-agents-messaging--prune)
    (let ((emacs-agents-messaging--ticking t) (reserved (make-hash-table :test #'equal)))
      (dolist (r (hash-table-values emacs-agents-messaging--records))
        (when (member (alist-get 'status r) '("sending" "working")) (puthash (alist-get 'target r) t reserved)))
      (dolist (r (sort (hash-table-values emacs-agents-messaging--records)
                      (lambda (a b) (< (alist-get 'created a) (alist-get 'created b)))))
        (when (member (alist-get 'status r) emacs-agents-messaging--pending)
          (condition-case err
              (let* ((id (alist-get 'target r)) (session (emacs-agents-session id t))
                     (entry (gethash id emacs-agents--running)) (transport (cdr entry))
                     (state (alist-get 'status r)))
                (cond
                 ((or (not session) (emacs-agents-archived-p session) (not entry)
                      (emacs-agents-transport-stopping transport) (emacs-agents-transport-failed transport)
                      (not (process-live-p (emacs-agents-backend-process transport)))
                      (and (not (equal state "queued")) (not (equal (car entry) (alist-get 'run r)))))
                  (emacs-agents-messaging--finish r "failed" nil "Recipient stopped, changed run, or was removed; no replay"))
                 ((> (- (float-time) (alist-get 'created r)) 1800)
                  (emacs-agents-messaging--finish r "failed" nil "Request expired after 30 minutes; inspect the conversation"))
                 ((and (equal state "sending") (> (- (float-time) (alist-get 'sent r)) 15))
                  (emacs-agents-messaging--finish r "failed" nil "Submission was not acknowledged; inspect before sending again"))
                 ((and (equal state "queued") (not (gethash id reserved)))
                  (puthash id t reserved)
                  (let ((hold (emacs-agents-messaging--hold session transport)))
                    (setf (alist-get 'hold r) hold)
                    (unless hold
                      (setf (alist-get 'run r) (car entry) (alist-get 'status r) "sending"
                            (alist-get 'sent r) (float-time))
                      (emacs-agents-messaging--save r)
                      (when-let* ((file (emacs-agents-messaging--marker transport)))
                        (with-temp-file file (insert (alist-get 'id r)))
                        (set-file-modes file #o600))
                      (emacs-agents-messaging--deliver r transport))))))
            (error (emacs-agents-messaging--finish r "failed" nil (error-message-string err)))))))))

(defun emacs-agents-messaging--observe (transport kind data)
  "Correlate TRANSPORT's normalized KIND and DATA with one submitted request."
  (when (buffer-live-p (emacs-agents-transport-buffer transport))
    (when (eq kind 'prompt)
      (with-current-buffer (emacs-agents-transport-buffer transport)
        (when (= emacs-agents-messaging--input-generation (or emacs-agents-messaging--submitted-generation 0))
          (setq emacs-agents-messaging--draft nil))))
    (dolist (r (hash-table-values emacs-agents-messaging--records))
      (let ((entry (gethash (alist-get 'target r) emacs-agents--running)))
        (when (and (eq transport (cdr entry)) (equal (car entry) (alist-get 'run r))
                   (member (alist-get 'status r) '("sending" "working")))
          (pcase kind
            ('prompt
             (if (and (equal (alist-get 'status r) "sending")
                      (equal (plist-get data :hash) (secure-hash 'sha256 (encode-coding-string (alist-get 'prompt r) 'utf-8-unix))))
                 (progn (setf (alist-get 'status r) "working") (emacs-agents-messaging--save r))
               (emacs-agents-messaging--finish r "failed" nil "A different prompt was submitted; reply attribution is uncertain")))
            ('reply-chunk
             (when (equal (alist-get 'status r) "working")
               (setf (alist-get 'response r) (concat (alist-get 'response r) data))
               (when (> (string-bytes (alist-get 'response r)) 131072)
                 (emacs-agents-messaging--finish r "failed" nil "Reply exceeded 128 KiB; read it in the conversation"))))
            ('turn-ended
             (when (and (equal (alist-get 'status r) "working")
                        (or (not (emacs-agents--terminal-transport-p transport))
                            (plist-get data :error)
                            (equal (plist-get data :request) (alist-get 'id r))))
               (let ((reply (or (plist-get data :text) (alist-get 'response r))))
                 (if (or (plist-get data :error) (not (stringp reply)) (string-empty-p reply) (> (string-bytes reply) 131072))
                     (emacs-agents-messaging--finish r "failed" nil (or (plist-get data :error) "No complete text reply available; inspect the conversation"))
                   (emacs-agents-messaging--finish r "completed" reply)))))))))))

(defun emacs-agents-messaging--detach ()
  "Release messaging observers without stopping any agent."
  (when emacs-agents-messaging--timer (cancel-timer emacs-agents-messaging--timer))
  (setq emacs-agents-messaging--timer nil)
  (remove-hook 'emacs-agents-backend-event-hook #'emacs-agents-messaging--event)
  (dolist (fn '(vterm-send-string vterm-insert))
    (advice-remove fn #'emacs-agents-messaging--input))
  (advice-remove 'eat--send-input #'emacs-agents-messaging--eat-input)
  (advice-remove 'vterm-send-key #'emacs-agents-messaging--vterm-key)
  (maphash (lambda (_id entry)
             (when-let* ((file (emacs-agents-messaging--marker (cdr entry))))
               (when (file-exists-p file) (ignore-errors (delete-file file)))))
           emacs-agents--running))

(defun emacs-agents-messaging--disable-on-error (error)
  "Isolate a messaging storage ERROR from otherwise healthy agent transports."
  (setq emacs-agents-messaging-mode nil)
  (emacs-agents-messaging--detach)
  (message "Agent messaging disabled: %s" (error-message-string error)))

(defun emacs-agents-messaging--tick ()
  "Advance the queue without allowing storage failures to stop agent processes."
  (condition-case err (emacs-agents-messaging--tick-1)
    (error (emacs-agents-messaging--disable-on-error err))))

(defun emacs-agents-messaging--event (transport kind data)
  "Observe TRANSPORT's KIND and DATA, isolating message-storage errors."
  (condition-case err (emacs-agents-messaging--observe transport kind data)
    (error (emacs-agents-messaging--disable-on-error err))))

(defun emacs-agents-messaging--agent-info (session)
  "Return CLI metadata for SESSION."
  `((id . ,(emacs-agents-session-id session))
    (name . ,(emacs-agents-messaging--name session))
    (directory . ,(emacs-agents-session-directory session))
    (status . ,(emacs-agents-session-status session))
    (activity . ,(emacs-agents-session-activity session))))

(defun emacs-agents-messaging--process-sender (pid)
  "Find the live managed ancestor of CLI process PID, or return nil.
Never infer identity from a directory: several agents may share it.  Like
explicit sender IDs, PID is attribution within the local user's trust boundary."
  (let ((owners (make-hash-table :test #'eql)) seen sender)
    (maphash
     (lambda (id entry)
       (let* ((transport (cdr entry))
              (process (emacs-agents-backend-process transport)))
         (when (and (processp process) (process-live-p process)
                    (not (emacs-agents-transport-stopping transport))
                    (not (emacs-agents-transport-failed transport)))
           (puthash (process-id process) id owners))))
     emacs-agents--running)
    (while (and (integerp pid) (> pid 1) (not sender)
                (< (length seen) 64) (not (memq pid seen)))
      (push pid seen)
      (setq sender (gethash pid owners)
            pid (unless sender (alist-get 'ppid (process-attributes pid)))))
    sender))

(defun emacs-agents-messaging--sender (data)
  "Resolve explicit sender or managed process identity from CLI DATA."
  (or (alist-get 'sender data)
      (emacs-agents-messaging--process-sender (alist-get 'pid data))))

(defun emacs-agents-messaging-rpc (encoded)
  "Handle base64 ENCODED JSON from the local CLI; return base64 JSON.
This is a fixed data endpoint. No supplied text is evaluated as Lisp."
  (base64-encode-string
   (encode-coding-string
    (json-encode
     (condition-case err
         (progn
           (unless emacs-agents-messaging-mode (user-error "Enable emacs-agents-messaging-mode first"))
           (let* ((data (json-parse-string (decode-coding-string (base64-decode-string encoded) 'utf-8)
                                           :object-type 'alist :null-object nil :false-object nil))
                  (command (alist-get 'command data))
                  (record (gethash (alist-get 'request data) emacs-agents-messaging--records))
                  (result
                   (pcase command
                     ("list" (vconcat (mapcar #'emacs-agents-messaging--agent-info
                                              (emacs-agents-sessions))))
                     ("whoami"
                      (let ((sender (emacs-agents-messaging--sender data)))
                        (unless sender
                          (user-error "No managed agent identity found; run whoami inside a managed agent process"))
                        (emacs-agents-messaging--agent-info
                         (emacs-agents-messaging--resolve sender))))
                     ("send" (emacs-agents-messaging-send (alist-get 'target data) (alist-get 'text data)
                                                          (emacs-agents-messaging--sender data) (alist-get 'request data)))
                     ((or "result" "cancel")
                      (unless record (user-error "Unknown request ID"))
                      (when (equal command "cancel")
                        (unless (equal (alist-get 'status record) "queued")
                          (user-error "Only queued requests can be cancelled; use the conversation to interrupt a submitted turn"))
                        (emacs-agents-messaging--finish record "cancelled"))
                      record)
                     (_ (user-error "Unknown messaging command")))))
             `((ok . t) (result . ,result))))
       (error `((ok . :json-false) (error . ,(error-message-string err))))))
    'utf-8-unix) t))

(defun emacs-agents-messaging-environment (id)
  "Return CLI discovery environment for agent ID when messaging is enabled."
  (when emacs-agents-messaging-mode
    (list (concat "EMACS_AGENTS_ID=" id)
          (concat "EMACS_AGENTS_CLI=" emacs-agents-messaging--script)
          (concat "EMACS_AGENTS_SOCKET=" (expand-file-name server-name server-socket-dir)))))

;;;###autoload
(define-minor-mode emacs-agents-messaging-mode
  "Allow local CLI requests to queue prompts and retrieve correlated replies.
Enable explicitly. Messages and replies are stored privately under the registry.
Existing terminal prompts are held until confirmed empty or submitted normally."
  :global t :group 'emacs-agents
  (if emacs-agents-messaging-mode
      (unless emacs-agents-messaging--timer
        (condition-case err
          (progn
            (when server-use-tcp (user-error "CLI messaging requires a local Unix Emacs server"))
            (emacs-agents-store-open)
            (make-directory (emacs-agents-messaging--directory) t)
            (set-file-modes (emacs-agents-messaging--directory) #o700)
            (clrhash emacs-agents-messaging--records)
            (dolist (file (directory-files (emacs-agents-messaging--directory) t "\\.json\\'"))
              (let ((record (with-temp-buffer (insert-file-contents file)
                                              (json-parse-buffer :object-type 'alist :null-object nil :false-object nil))))
                (if (member (alist-get 'status record) emacs-agents-messaging--pending)
                    (emacs-agents-messaging--finish record "failed" nil "Messaging restarted; request was not replayed")
                  (puthash (alist-get 'id record) record emacs-agents-messaging--records))))
            (maphash (lambda (_id entry)
                       (let ((buffer (emacs-agents-transport-buffer (cdr entry))))
                         (when (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (setq emacs-agents-messaging--draft t
                                   emacs-agents-messaging--input-generation 1
                                   emacs-agents-messaging--submitted-generation nil)))))
                     emacs-agents--running)
            (unless (and server-process (process-live-p server-process)) (server-start))
            (dolist (fn '(vterm-send-string vterm-insert))
              (advice-add fn :before #'emacs-agents-messaging--input))
            (advice-add 'eat--send-input :before #'emacs-agents-messaging--eat-input)
            (advice-add 'vterm-send-key :before #'emacs-agents-messaging--vterm-key)
            (add-hook 'emacs-agents-backend-event-hook #'emacs-agents-messaging--event)
            (unless emacs-agents-messaging--timer
              (setq emacs-agents-messaging--timer (run-at-time 0.5 0.5 #'emacs-agents-messaging--tick))))
        (error (emacs-agents-messaging--disable-on-error err) (signal (car err) (cdr err)))))
    (emacs-agents-messaging--detach)
    (dolist (record (hash-table-values emacs-agents-messaging--records))
      (when (member (alist-get 'status record) emacs-agents-messaging--pending)
        (emacs-agents-messaging--finish record "failed" nil "Messaging disabled; request was not replayed")))))

(provide 'emacs-agents-messaging)
;;; emacs-agents-messaging.el ends here
