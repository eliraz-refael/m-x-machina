;;; emacs-agents-agent-shell.el --- Structured interactive adapter -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; agent-shell 0.75.2 compatibility boundary.  Guard all conversation creation
;; and restoration requests: upstream can otherwise fall back to new sessions.
;;; Code:
(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)
(defvar agent-shell-agent-configs)
(defvar agent-shell-session-strategy)
(defvar agent-shell--state)
(declare-function agent-shell-start "agent-shell")
(declare-function agent-shell-subscribe-to "agent-shell")
(declare-function agent-shell-status "agent-shell")
(declare-function agent-shell-interrupt "agent-shell")
(declare-function acp-shutdown "acp")

(cl-defstruct (emacs-agents-transport (:constructor emacs-agents--transport-create))
  buffer callback conversation ready failed stopping)

(defun emacs-agents-backend-configs ()
  "Resolve configured agent-shell profiles without launching agents."
  (unless (require 'agent-shell nil t)
    (user-error "Install agent-shell 0.75.2 or later to launch sessions"))
  (mapcar (lambda (entry) (if (functionp entry) (funcall entry) entry))
          (if (functionp agent-shell-agent-configs)
              (funcall agent-shell-agent-configs)
            agent-shell-agent-configs)))

(defun emacs-agents-backend-process (transport)
  "Return TRANSPORT's ACP process through the compatibility boundary."
  (when (buffer-live-p (emacs-agents-transport-buffer transport))
    (with-current-buffer (emacs-agents-transport-buffer transport)
      (map-nested-elt agent-shell--state '(:client :process)))))

(defun emacs-agents-backend-stop (transport)
  "Stop TRANSPORT while retaining its buffer for inspection."
  (setf (emacs-agents-transport-stopping transport) t)
  (when (buffer-live-p (emacs-agents-transport-buffer transport))
    (with-current-buffer (emacs-agents-transport-buffer transport)
      (when-let* ((client (map-elt agent-shell--state :client)))
        (ignore-errors (agent-shell-interrupt t))
        (acp-shutdown :client client)))))

(defun emacs-agents--transport-fail (transport message)
  "Record MESSAGE and stop TRANSPORT without permitting replacement."
  (unless (emacs-agents-transport-failed transport)
    (setf (emacs-agents-transport-failed transport) t)
    (funcall (emacs-agents-transport-callback transport) "failed" "unknown" nil message)
    ;; Avoid tearing down the client inside its own request/response dispatch.
    (run-at-time 0 nil #'emacs-agents-backend-stop transport)))

(defun emacs-agents--guard-request (transport request)
  "Check REQUEST against TRANSPORT's fixed conversation identity."
  (when (emacs-agents-transport-stopping transport)
    (user-error "This run is stopped; resume it from the Emacs Agents dashboard"))
  (let* ((method (map-elt request :method))
         (expected (emacs-agents-transport-conversation transport))
         (requested (map-nested-elt request '(:params sessionId))))
    (when (or (emacs-agents-transport-failed transport)
              (and expected (member method '("session/new" "session/list" "session/fork")))
              (and (member method '("session/load" "session/resume" "session/prompt"))
                   (not (equal expected requested))))
      (let ((message "Conversation replacement blocked; inspect the session error and retry its saved ID"))
        (emacs-agents--transport-fail transport message)
        (error "%s" message))))
  request)

(defun emacs-agents--transport-event (transport event)
  "Translate agent-shell EVENT into a TRANSPORT observation."
  (when (and (not (emacs-agents-transport-failed transport))
             (not (emacs-agents-transport-stopping transport))
             (memq (map-elt event :event)
                   '(init-session init-finished input-submitted permission-request
                     permission-response turn-complete error clean-up)))
    (let* ((buffer (emacs-agents-transport-buffer transport))
           (kind (map-elt event :event))
           (conversation (with-current-buffer buffer
                           (map-nested-elt agent-shell--state '(:session :id))))
           (expected (emacs-agents-transport-conversation transport)))
      (cond
       ((and conversation expected (not (equal conversation expected)))
        (emacs-agents--transport-fail transport "Backend returned a different conversation ID"))
       ((eq kind 'clean-up)
        (funcall (emacs-agents-transport-callback transport) "stopped" "unknown"))
       ((and (eq kind 'error) (not (emacs-agents-transport-ready transport)))
        (emacs-agents--transport-fail
         transport (or (map-nested-elt event '(:data :message)) "Initialization failed")))
       (t
        (when conversation
          (setf (emacs-agents-transport-conversation transport) conversation))
        (when (eq kind 'init-finished)
          (if (and (stringp conversation) (not (string-empty-p conversation)))
              (setf (emacs-agents-transport-ready transport) t)
            (emacs-agents--transport-fail transport "Backend did not report a conversation ID")))
        (unless (emacs-agents-transport-failed transport)
          (let ((ready (emacs-agents-transport-ready transport)))
            (funcall
             (emacs-agents-transport-callback transport)
             (if ready "live" "starting")
             (if ready
                 (pcase (agent-shell-status :shell-buffer buffer)
                   ('busy "working") ('blocked "approval") (_ "input"))
               "unknown")
             conversation
             (when (eq kind 'error) (map-nested-elt event '(:data :message)))))))))))

(defun emacs-agents-backend-start (profile directory conversation callback)
  "Start PROFILE in DIRECTORY, restoring CONVERSATION when supplied.
Report normalized observations to CALLBACK.  Return a transport object."
  (let* ((config (seq-find
                  (lambda (entry) (equal profile (symbol-name (map-elt entry :identifier))))
                  (emacs-agents-backend-configs)))
         (transport (emacs-agents--transport-create :callback callback :conversation conversation))
         (default-directory directory)
         (agent-shell-session-strategy 'new))
    (unless config (user-error "Agent profile %s is unavailable" profile))
    (setf (emacs-agents-transport-buffer transport)
          (save-window-excursion
            (agent-shell-start
             :config config :session-id conversation
             :outgoing-request-decorator
             (lambda (request) (emacs-agents--guard-request transport request)))))
    (agent-shell-subscribe-to
     :shell-buffer (emacs-agents-transport-buffer transport)
     :on-event (lambda (event) (emacs-agents--transport-event transport event)))
    transport))

(provide 'emacs-agents-agent-shell)
;;; emacs-agents-agent-shell.el ends here
