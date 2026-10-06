;;; mx-machina-messaging.el --- Correlated local agent messages -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eliraz Kedmi
;; Author: Eliraz Kedmi <eliraz.kedmi@gmail.com>
;; Assisted-by: Codex:gpt-6
;; Maintainer: Eliraz Kedmi <eliraz.kedmi@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later
;; This file is part of M-x Machina.
;;
;; M-x Machina is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; M-x Machina is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with M-x Machina.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Opt-in delivery through existing transports.  No background launches or replay.
;;; Code:
(require 'mx-machina)
(require 'mx-machina-resources)
(require 'json)
(require 'server)
(defvar eat-terminal)
(declare-function eat-term-send-string-as-yank "eat")
(declare-function eat-term-send-string "eat")
(declare-function vterm-send-string "vterm")
(declare-function vterm-send-return "vterm")
(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell--prompt-input-start "agent-shell")
(defvar mx-machina-messaging-mode)
(defvar mx-machina-messaging--records (make-hash-table :test #'equal))
(defvar mx-machina-messaging--timer nil)
(defvar mx-machina-messaging--sending nil)
(defvar mx-machina-messaging--ticking nil)
(defvar-local mx-machina-messaging--draft t)
(defvar-local mx-machina-messaging--input-generation 0)
(defvar-local mx-machina-messaging--submitted-generation nil)
(defvar mx-machina-messaging--last-prune 0)
(defcustom mx-machina-messaging-retention-days 7
  "Days to retain completed CLI messages and their idempotency keys."
  :type 'natnum :group 'mx-machina)
(defconst mx-machina-messaging--script
  (mx-machina--resource-file "scripts/mxm"))
(defconst mx-machina-messaging--pending '("queued" "sending" "working"))

(defun mx-machina-messaging--directory ()
  "Return this registry's private message directory."
  (expand-file-name "messages/" mx-machina-directory))

(defun mx-machina-messaging--save (record)
  "Atomically persist RECORD before allowing any terminal side effect."
  (let* ((directory (mx-machina-messaging--directory))
         (file (expand-file-name (concat (alist-get 'id record) ".json") directory))
         (temporary (make-temp-file (expand-file-name ".write-" directory))))
    (unwind-protect
        (progn
          (set-file-modes temporary #o600)
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file temporary (insert (json-encode record))))
          (rename-file temporary file t)
          (puthash (alist-get 'id record) record mx-machina-messaging--records))
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun mx-machina-messaging--marker (transport)
  "Return TRANSPORT's hook correlation marker, when it is a terminal."
  (when (mx-machina--terminal-transport-p transport)
    (with-current-buffer (mx-machina-transport-buffer transport)
      (expand-file-name "message-request" mx-machina-claude--run-directory))))

(defun mx-machina-messaging--finish (record status &optional response error)
  "Save terminal STATUS and optional RESPONSE or ERROR for RECORD."
  (when (and (equal status "failed") (member (alist-get 'status record) '("sending" "working")))
    (when-let* ((entry (gethash (alist-get 'target record) mx-machina--running)))
      (when (and (equal (car entry) (alist-get 'run record))
                 (mx-machina--terminal-transport-p (cdr entry)))
        (with-current-buffer (mx-machina-transport-buffer (cdr entry))
          (setq mx-machina-messaging--draft t)))))
  (setf (alist-get 'status record) status
        (alist-get 'response record) response
        (alist-get 'error record) error)
  (mx-machina-messaging--save record)
  (when-let* ((entry (gethash (alist-get 'target record) mx-machina--running))
              (file (mx-machina-messaging--marker (cdr entry))))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (when (equal (buffer-string) (alist-get 'id record)) (delete-file file))))))

(defun mx-machina-messaging--resolve (target)
  "Resolve TARGET as an exact ID or unambiguous full folder/name."
  (or (mx-machina-session target t)
      (let ((matches (seq-filter
                      (lambda (s) (equal target (mx-machina-messaging--name s)))
                      (mx-machina-sessions))))
        (unless (= (length matches) 1)
          (user-error "Use an exact agent ID or unique full folder/name (see CLI list)"))
        (car matches))))

(defun mx-machina-messaging--name (session)
  "Return SESSION's full logical name."
  (string-join (seq-remove #'string-empty-p
                           (list (mx-machina-session-folder session) (mx-machina-session-name session))) "/"))

(defun mx-machina-messaging--cycle-p (sender target &optional seen)
  "Return non-nil if adding SENDER to TARGET would create a pending cycle.
SEEN contains session IDs already visited during this traversal."
  (or (equal sender target)
      (and (not (member target seen))
           (seq-some (lambda (r)
                       (and (member (alist-get 'status r) mx-machina-messaging--pending)
                            (equal (alist-get 'sender r) target)
                            (mx-machina-messaging--cycle-p sender (alist-get 'target r) (cons target seen))))
                     (hash-table-values mx-machina-messaging--records)))))

(defun mx-machina-messaging-send (target text &optional sender request)
  "Queue TEXT to TARGET, with optional SENDER and idempotent REQUEST ID."
  (unless mx-machina-messaging-mode (user-error "Enable mx-machina-messaging-mode first"))
  (unless (and (stringp text) (not (string-empty-p (string-trim text))) (<= (string-bytes text) 16384))
    (user-error "Use a nonempty message of at most 16 KiB"))
  (setq request (or request (mx-machina-claude--uuid)))
  (unless (and (stringp request) (string-match-p "\\`[a-zA-Z0-9-]\\{8,80\\}\\'" request))
    (user-error "Invalid request ID"))
  (let* ((session (mx-machina-messaging--resolve target))
         (id (mx-machina-session-id session))
         (source (when sender (mx-machina-messaging--resolve sender)))
         (source-id (and source (mx-machina-session-id source)))
         (existing (gethash request mx-machina-messaging--records)))
    (if existing
        (progn
          (unless (and (equal text (alist-get 'text existing))
                       (equal id (alist-get 'target existing)) (equal source-id (alist-get 'sender existing)))
            (user-error "Request ID already belongs to a different message"))
          existing)
      (when (mx-machina-archived-p session) (user-error "Restore the recipient first"))
      (unless (gethash id mx-machina--running) (user-error "Start the recipient first; messaging does not launch agents"))
      (when (and source-id (mx-machina-messaging--cycle-p source-id id))
        (user-error "This message would create a pending request cycle"))
      (when (>= (seq-count (lambda (r) (member (alist-get 'status r) mx-machina-messaging--pending))
                           (hash-table-values mx-machina-messaging--records)) 100)
        (user-error "Message queue is full"))
      (let* ((payload (format "[M-x Machina request %s from %s] Reply to this message normally; your completed reply is returned to the caller. Message (JSON string): %s"
                              request (if source (mx-machina-messaging--name source) "user CLI") (json-encode text)))
             (record (copy-tree `((id . ,request) (target . ,id) (sender . ,source-id)
                       (text . ,text) (prompt . ,payload) (status . "queued")
                       (hold . nil) (run . nil) (sent . nil)
                       (created . ,(float-time)) (response . nil) (error . nil)))))
        (mx-machina-messaging--save record)
        record))))

(defun mx-machina-messaging--input (&rest _)
  "Conservatively remember terminal input until its prompt is acknowledged."
  (when (and mx-machina-messaging-mode (not mx-machina-messaging--sending)
             mx-machina--managed-id)
    (setq mx-machina-messaging--draft t)
    (cl-incf mx-machina-messaging--input-generation)))

(defun mx-machina-messaging--eat-input (_terminal input)
  "Track INPUT and recognize submission without clearing a later draft."
  (mx-machina-messaging--input)
  (when (and mx-machina-messaging-mode mx-machina--managed-id
             (not mx-machina-messaging--sending) (member input '("\r" "\n")))
    (setq mx-machina-messaging--submitted-generation mx-machina-messaging--input-generation)))

(defun mx-machina-messaging--vterm-key (key &rest _)
  "Track KEY and remember the generation submitted by Return."
  (mx-machina-messaging--input)
  (when (and mx-machina-messaging-mode mx-machina--managed-id
             (not mx-machina-messaging--sending) (equal key "<return>"))
    (setq mx-machina-messaging--submitted-generation mx-machina-messaging--input-generation)))

(defun mx-machina-messaging--prune ()
  "Expire completed mailbox records while retaining all pending requests."
  (when (> (- (float-time) mx-machina-messaging--last-prune) 60)
    (setq mx-machina-messaging--last-prune (float-time))
    (let ((cutoff (- (float-time) (* 86400 (max 1 mx-machina-messaging-retention-days)))))
      (dolist (record (hash-table-values mx-machina-messaging--records))
        (when (and (not (member (alist-get 'status record) mx-machina-messaging--pending))
                   (< (alist-get 'created record) cutoff))
          (delete-file (expand-file-name (concat (alist-get 'id record) ".json") (mx-machina-messaging--directory)))
          (remhash (alist-get 'id record) mx-machina-messaging--records))))))

;;;###autoload
(defun mx-machina-messaging-ready (id)
  "Allow delivery to ID after the user confirms its terminal prompt is empty."
  (interactive (list (mx-machina--read-id)))
  (let* ((entry (gethash id mx-machina--running))
         (buffer (and entry (mx-machina-transport-buffer (cdr entry)))))
    (unless (buffer-live-p buffer) (user-error "Start the agent first"))
    (unless (yes-or-no-p "Is the agent's input prompt empty, with no draft or dialog? ")
      (user-error "Delivery remains held"))
    (with-current-buffer buffer (setq mx-machina-messaging--draft nil))))

(defun mx-machina-messaging--hold (session transport)
  "Explain why SESSION and TRANSPORT cannot receive a new message yet."
  (let ((buffer (mx-machina-transport-buffer transport)))
    (cond
     ((or (not (mx-machina-transport-ready transport))
          (not (equal (mx-machina-session-status session) "live"))
          (not (equal (mx-machina-session-activity session) "input"))) "Agent is not ready (busy, starting or waiting for approval)")
     ((not (buffer-live-p buffer)) "Conversation buffer is unavailable")
     ((and (mx-machina--terminal-transport-p transport)
           (buffer-local-value 'mx-machina-claude--turn-active buffer)) "Previous terminal turn is still active")
     ((get-buffer-window buffer t) "Conversation is visible; hide it to allow delivery")
     (t
      (with-current-buffer buffer
        (if (mx-machina--terminal-transport-p transport)
            (when mx-machina-messaging--draft "Terminal may contain a draft; submit it or use M-x mx-machina-messaging-ready")
          (let ((start (agent-shell--prompt-input-start)))
            (when (or (not start) (not (string-empty-p (string-trim (buffer-substring-no-properties start (point-max))))))
              "Conversation contains a draft or has no prompt"))))))))

(defun mx-machina-messaging--deliver (record transport)
  "Submit RECORD through TRANSPORT without taking keyboard focus."
  (let ((prompt (alist-get 'prompt record))
        (mx-machina-messaging--sending t))
    (with-current-buffer (mx-machina-transport-buffer transport)
      (pcase mx-machina--backend-kind
        ('eat (eat-term-send-string-as-yank eat-terminal (list prompt))
              (eat-term-send-string eat-terminal "\r"))
        ('vterm (vterm-send-string prompt t) (vterm-send-return))
        (_ (agent-shell-insert :text prompt :submit t :no-focus t :shell-buffer (current-buffer)))))))

(defun mx-machina-messaging--tick-1 ()
  "Advance the queue, never retrying an uncertain submission."
  (when (and mx-machina-messaging-mode (not mx-machina-messaging--ticking))
    (mx-machina-messaging--prune)
    (let ((mx-machina-messaging--ticking t) (reserved (make-hash-table :test #'equal)))
      (dolist (r (hash-table-values mx-machina-messaging--records))
        (when (member (alist-get 'status r) '("sending" "working")) (puthash (alist-get 'target r) t reserved)))
      (dolist (r (sort (hash-table-values mx-machina-messaging--records)
                      (lambda (a b) (< (alist-get 'created a) (alist-get 'created b)))))
        (when (member (alist-get 'status r) mx-machina-messaging--pending)
          (condition-case err
              (let* ((id (alist-get 'target r)) (session (mx-machina-session id t))
                     (entry (gethash id mx-machina--running)) (transport (cdr entry))
                     (state (alist-get 'status r)))
                (cond
                 ((or (not session) (mx-machina-archived-p session) (not entry)
                      (mx-machina-transport-stopping transport) (mx-machina-transport-failed transport)
                      (not (process-live-p (mx-machina-backend-process transport)))
                      (and (not (equal state "queued")) (not (equal (car entry) (alist-get 'run r)))))
                  (mx-machina-messaging--finish r "failed" nil "Recipient stopped, changed run, or was removed; no replay"))
                 ((> (- (float-time) (alist-get 'created r)) 1800)
                  (mx-machina-messaging--finish r "failed" nil "Request expired after 30 minutes; inspect the conversation"))
                 ((and (equal state "sending") (> (- (float-time) (alist-get 'sent r)) 15))
                  (mx-machina-messaging--finish r "failed" nil "Submission was not acknowledged; inspect before sending again"))
                 ((and (equal state "queued") (not (gethash id reserved)))
                  (puthash id t reserved)
                  (let ((hold (mx-machina-messaging--hold session transport)))
                    (setf (alist-get 'hold r) hold)
                    (unless hold
                      (setf (alist-get 'run r) (car entry) (alist-get 'status r) "sending"
                            (alist-get 'sent r) (float-time))
                      (mx-machina-messaging--save r)
                      (when-let* ((file (mx-machina-messaging--marker transport)))
                        (with-temp-file file (insert (alist-get 'id r)))
                        (set-file-modes file #o600))
                      (mx-machina-messaging--deliver r transport))))))
            (error (mx-machina-messaging--finish r "failed" nil (error-message-string err)))))))))

(defun mx-machina-messaging--observe (transport kind data)
  "Correlate TRANSPORT's normalized KIND and DATA with one submitted request."
  (when (buffer-live-p (mx-machina-transport-buffer transport))
    (when (eq kind 'prompt)
      (with-current-buffer (mx-machina-transport-buffer transport)
        (when (= mx-machina-messaging--input-generation (or mx-machina-messaging--submitted-generation 0))
          (setq mx-machina-messaging--draft nil))))
    (dolist (r (hash-table-values mx-machina-messaging--records))
      (let ((entry (gethash (alist-get 'target r) mx-machina--running)))
        (when (and (eq transport (cdr entry)) (equal (car entry) (alist-get 'run r))
                   (member (alist-get 'status r) '("sending" "working")))
          (pcase kind
            ('prompt
             (if (and (equal (alist-get 'status r) "sending")
                      (equal (plist-get data :hash) (secure-hash 'sha256 (encode-coding-string (alist-get 'prompt r) 'utf-8-unix))))
                 (progn (setf (alist-get 'status r) "working") (mx-machina-messaging--save r))
               (mx-machina-messaging--finish r "failed" nil "A different prompt was submitted; reply attribution is uncertain")))
            ('reply-chunk
             (when (equal (alist-get 'status r) "working")
               (setf (alist-get 'response r) (concat (alist-get 'response r) data))
               (when (> (string-bytes (alist-get 'response r)) 131072)
                 (mx-machina-messaging--finish r "failed" nil "Reply exceeded 128 KiB; read it in the conversation"))))
            ('turn-ended
             (when (and (equal (alist-get 'status r) "working")
                        (or (not (mx-machina--terminal-transport-p transport))
                            (plist-get data :error)
                            (equal (plist-get data :request) (alist-get 'id r))))
               (let ((reply (or (plist-get data :text) (alist-get 'response r))))
                 (if (or (plist-get data :error) (not (stringp reply)) (string-empty-p reply) (> (string-bytes reply) 131072))
                     (mx-machina-messaging--finish r "failed" nil (or (plist-get data :error) "No complete text reply available; inspect the conversation"))
                   (mx-machina-messaging--finish r "completed" reply)))))))))))

(defun mx-machina-messaging--detach ()
  "Release messaging observers without stopping any agent."
  (when mx-machina-messaging--timer (cancel-timer mx-machina-messaging--timer))
  (setq mx-machina-messaging--timer nil)
  (remove-hook 'mx-machina-backend-event-hook #'mx-machina-messaging--event)
  (dolist (fn '(vterm-send-string vterm-insert))
    (advice-remove fn #'mx-machina-messaging--input))
  (advice-remove 'eat--send-input #'mx-machina-messaging--eat-input)
  (advice-remove 'vterm-send-key #'mx-machina-messaging--vterm-key)
  (maphash (lambda (_id entry)
             (when-let* ((file (mx-machina-messaging--marker (cdr entry))))
               (when (file-exists-p file) (ignore-errors (delete-file file)))))
           mx-machina--running))

(defun mx-machina-messaging--disable-on-error (error)
  "Isolate a messaging storage ERROR from otherwise healthy agent transports."
  (setq mx-machina-messaging-mode nil)
  (mx-machina-messaging--detach)
  (message "Agent messaging disabled: %s" (error-message-string error)))

(defun mx-machina-messaging--tick ()
  "Advance the queue without allowing storage failures to stop agent processes."
  (condition-case err (mx-machina-messaging--tick-1)
    (error (mx-machina-messaging--disable-on-error err))))

(defun mx-machina-messaging--event (transport kind data)
  "Observe TRANSPORT's KIND and DATA, isolating message-storage errors."
  (condition-case err (mx-machina-messaging--observe transport kind data)
    (error (mx-machina-messaging--disable-on-error err))))

(defun mx-machina-messaging--agent-info (session)
  "Return CLI metadata for SESSION."
  `((id . ,(mx-machina-session-id session))
    (name . ,(mx-machina-messaging--name session))
    (directory . ,(mx-machina-session-directory session))
    (status . ,(mx-machina-session-status session))
    (activity . ,(mx-machina-session-activity session))))

(defun mx-machina-messaging--process-sender (pid)
  "Find the live managed ancestor of CLI process PID, or return nil.
Never infer identity from a directory: several agents may share it.  Like
explicit sender IDs, PID is attribution within the local user's trust boundary."
  (let ((owners (make-hash-table :test #'eql)) seen sender)
    (maphash
     (lambda (id entry)
       (let* ((transport (cdr entry))
              (process (mx-machina-backend-process transport)))
         (when (and (processp process) (process-live-p process)
                    (not (mx-machina-transport-stopping transport))
                    (not (mx-machina-transport-failed transport)))
           (puthash (process-id process) id owners))))
     mx-machina--running)
    (while (and (integerp pid) (> pid 1) (not sender)
                (< (length seen) 64) (not (memq pid seen)))
      (push pid seen)
      (setq sender (gethash pid owners)
            pid (unless sender (alist-get 'ppid (process-attributes pid)))))
    sender))

(defun mx-machina-messaging--sender (data)
  "Resolve explicit sender or managed process identity from CLI DATA."
  (or (alist-get 'sender data)
      (mx-machina-messaging--process-sender (alist-get 'pid data))))

(defun mx-machina-messaging-rpc (encoded)
  "Handle base64 ENCODED JSON from the local CLI; return base64 JSON.
This is a fixed data endpoint.  No supplied text is evaluated as Lisp."
  (base64-encode-string
   (encode-coding-string
    (json-encode
     (condition-case err
         (progn
           (unless mx-machina-messaging-mode (user-error "Enable mx-machina-messaging-mode first"))
           (let* ((data (json-parse-string (decode-coding-string (base64-decode-string encoded) 'utf-8)
                                           :object-type 'alist :null-object nil :false-object nil))
                  (command (alist-get 'command data))
                  (record (gethash (alist-get 'request data) mx-machina-messaging--records))
                  (result
                   (pcase command
                     ("list" (vconcat (mapcar #'mx-machina-messaging--agent-info
                                              (mx-machina-sessions))))
                     ("whoami"
                      (let ((sender (mx-machina-messaging--sender data)))
                        (unless sender
                          (user-error "No managed agent identity found; run whoami inside a managed agent process"))
                        (mx-machina-messaging--agent-info
                         (mx-machina-messaging--resolve sender))))
                     ("send" (mx-machina-messaging-send (alist-get 'target data) (alist-get 'text data)
                                                          (mx-machina-messaging--sender data) (alist-get 'request data)))
                     ((or "result" "cancel")
                      (unless record (user-error "Unknown request ID"))
                      (when (equal command "cancel")
                        (unless (equal (alist-get 'status record) "queued")
                          (user-error "Only queued requests can be cancelled; use the conversation to interrupt a submitted turn"))
                        (mx-machina-messaging--finish record "cancelled"))
                      record)
                     (_ (user-error "Unknown messaging command")))))
             `((ok . t) (result . ,result))))
       (error `((ok . :json-false) (error . ,(error-message-string err))))))
    'utf-8-unix) t))

(defun mx-machina-messaging-environment (id)
  "Return CLI discovery environment for agent ID when messaging is enabled."
  (when mx-machina-messaging-mode
    (list (concat "EMACS_AGENTS_ID=" id)
          (concat "EMACS_AGENTS_CLI=" mx-machina-messaging--script)
          (concat "EMACS_AGENTS_SOCKET=" (expand-file-name server-name server-socket-dir)))))

;;;###autoload
(define-minor-mode mx-machina-messaging-mode
  "Allow local CLI requests to queue prompts and retrieve correlated replies.
Enable explicitly.  Store messages and replies privately under the registry.
Existing terminal prompts are held until confirmed empty or submitted normally."
  :global t :group 'mx-machina
  (if mx-machina-messaging-mode
      (unless mx-machina-messaging--timer
        (condition-case err
          (progn
            (when server-use-tcp (user-error "CLI messaging requires a local Unix Emacs server"))
            (mx-machina-store-open)
            (make-directory (mx-machina-messaging--directory) t)
            (set-file-modes (mx-machina-messaging--directory) #o700)
            (clrhash mx-machina-messaging--records)
            (dolist (file (directory-files (mx-machina-messaging--directory) t "\\.json\\'"))
              (let ((record (with-temp-buffer (insert-file-contents file)
                                              (json-parse-buffer :object-type 'alist :null-object nil :false-object nil))))
                (if (member (alist-get 'status record) mx-machina-messaging--pending)
                    (mx-machina-messaging--finish record "failed" nil "Messaging restarted; request was not replayed")
                  (puthash (alist-get 'id record) record mx-machina-messaging--records))))
            (maphash (lambda (_id entry)
                       (let ((buffer (mx-machina-transport-buffer (cdr entry))))
                         (when (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (setq mx-machina-messaging--draft t
                                   mx-machina-messaging--input-generation 1
                                   mx-machina-messaging--submitted-generation nil)))))
                     mx-machina--running)
            (unless (and server-process (process-live-p server-process)) (server-start))
            (dolist (fn '(vterm-send-string vterm-insert))
              (advice-add fn :before #'mx-machina-messaging--input))
            (advice-add 'eat--send-input :before #'mx-machina-messaging--eat-input)
            (advice-add 'vterm-send-key :before #'mx-machina-messaging--vterm-key)
            (add-hook 'mx-machina-backend-event-hook #'mx-machina-messaging--event)
            (unless mx-machina-messaging--timer
              (setq mx-machina-messaging--timer (run-at-time 0.5 0.5 #'mx-machina-messaging--tick))))
        (error (mx-machina-messaging--disable-on-error err) (signal (car err) (cdr err)))))
    (mx-machina-messaging--detach)
    (dolist (record (hash-table-values mx-machina-messaging--records))
      (when (member (alist-get 'status record) mx-machina-messaging--pending)
        (mx-machina-messaging--finish record "failed" nil "Messaging disabled; request was not replayed")))))

(provide 'mx-machina-messaging)
;;; mx-machina-messaging.el ends here
