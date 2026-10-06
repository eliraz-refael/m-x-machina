;;; mx-machina-agent-shell.el --- Structured interactive adapter -*- lexical-binding: t; -*-

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
;; agent-shell 0.83.4 compatibility boundary.  Guard all conversation creation
;; and restoration requests: upstream can otherwise fall back to new sessions.
;;; Code:
(require 'cl-lib)
(require 'mx-machina-transport)
(declare-function mx-machina--transport-fail "mx-machina-backend")
(declare-function mx-machina-backend-configs "mx-machina-backend")
(declare-function mx-machina-backend-metadata "mx-machina-backend")
(require 'map)
(require 'seq)
(require 'subr-x)
(defvar agent-shell-agent-configs)
(defvar agent-shell-session-strategy)
(defvar agent-shell--state)
(defvar-local mx-machina-agent-shell--transport nil)
(declare-function agent-shell-start "agent-shell")
(declare-function agent-shell-subscribe-to "agent-shell")
(declare-function agent-shell-status "agent-shell")
(declare-function agent-shell-interrupt "agent-shell")
(declare-function acp-shutdown "acp")
(declare-function agent-shell-get-model-name "agent-shell")
(defun mx-machina-agent-shell-metadata (transport)
  "Return backend-reported display metadata for TRANSPORT."
  (when (buffer-live-p (mx-machina-transport-buffer transport))
    (with-current-buffer (mx-machina-transport-buffer transport)
      (list :model (when (fboundp 'agent-shell-get-model-name)
                     (agent-shell-get-model-name agent-shell--state))))))

(defun mx-machina--retain-conversation-header (&rest _)
  "Retain the managed header after an agent-shell header update."
  (when (bound-and-true-p mx-machina-conversation-mode)
    (setq header-line-format '(:eval mx-machina--context))))

(with-eval-after-load 'agent-shell
  (advice-add 'agent-shell--update-header-and-mode-line :after
              #'mx-machina--retain-conversation-header))

(defun mx-machina-agent-shell--guard-send (&rest args)
  "Validate managed requests in ARGS before ACP can auto-start a client."
  (let* ((client (plist-get args :client))
         (buffer (map-elt client :context-buffer))
         (transport (and (buffer-live-p buffer)
                         (buffer-local-value 'mx-machina-agent-shell--transport buffer))))
    (when transport
      (mx-machina--guard-request transport (plist-get args :request)))))

(with-eval-after-load 'acp
  (advice-add 'acp-send-request :before #'mx-machina-agent-shell--guard-send))

(defun mx-machina-agent-shell-configs ()
  "Resolve configured agent-shell profiles without launching agents."
  (when (require 'agent-shell nil t)
    (mapcar (lambda (entry) (if (functionp entry) (funcall entry) entry))
          (if (functionp agent-shell-agent-configs)
              (funcall agent-shell-agent-configs)
            agent-shell-agent-configs))))

(defun mx-machina-agent-shell-process (transport)
  "Return TRANSPORT's ACP process through the compatibility boundary."
  (when (buffer-live-p (mx-machina-transport-buffer transport))
    (with-current-buffer (mx-machina-transport-buffer transport)
      (map-nested-elt agent-shell--state '(:client :process)))))

(defun mx-machina-agent-shell-stop (transport)
  "Stop TRANSPORT while retaining its buffer for inspection."
  (setf (mx-machina-transport-stopping transport) t)
  (when (buffer-live-p (mx-machina-transport-buffer transport))
    (with-current-buffer (mx-machina-transport-buffer transport)
      (setq mx-machina-agent-shell--transport transport)
      (when-let* ((client (map-elt agent-shell--state :client)))
        (ignore-errors (agent-shell-interrupt t))
        (acp-shutdown :client client)))))

(defun mx-machina--guard-request (transport request)
  "Check REQUEST against TRANSPORT's fixed conversation identity.
Read-only session/list requests also refresh titles during initialization;
listing does not change identity.  Guard the subsequent load/new/fork instead."
  (when (mx-machina-transport-stopping transport)
    (user-error "This run is stopped; resume it from the M-x Machina dashboard"))
  (let* ((method (map-elt request :method))
         (expected (mx-machina-transport-conversation transport))
         (requested (map-nested-elt request '(:params sessionId))))
    (when (or (mx-machina-transport-failed transport)
              (and expected (member method '("session/new" "session/fork")))
              (and (member method '("session/load" "session/resume" "session/prompt"))
                   (not (equal expected requested))))
      (let* ((state (when (buffer-live-p (mx-machina-transport-buffer transport))
                      (with-current-buffer (mx-machina-transport-buffer transport)
                        (bound-and-true-p agent-shell--state))))
             (fallback (and expected (member method '("session/new" "session/fork"))
                            (not (mx-machina-transport-ready transport))))
             (message
              (cond
               ((and fallback (assq :supports-session-load state) (assq :supports-session-resume state)
                     (not (map-elt state :supports-session-load)) (not (map-elt state :supports-session-resume)))
                "Unsupported resume: backend offers neither saved-session loading nor resuming; replacement blocked")
               (fallback "Resume failed: backend attempted a replacement; original conversation retained. Inspect account, history and worktree")
               (t "Conversation replacement blocked; inspect the session error and retry its saved ID"))))
        (mx-machina--transport-fail transport message)
        (error "%s" message))))
  request)

(defun mx-machina--transport-lifecycle-event (transport event)
  "Translate agent-shell EVENT into a TRANSPORT observation."
  (when (and (not (mx-machina-transport-failed transport))
             (not (mx-machina-transport-stopping transport))
             (memq (map-elt event :event)
                   '(init-session init-finished input-submitted permission-request
                     permission-response turn-complete error clean-up)))
    (let* ((buffer (mx-machina-transport-buffer transport))
           (kind (map-elt event :event))
           (conversation (with-current-buffer buffer
                           (map-nested-elt agent-shell--state '(:session :id))))
           (expected (mx-machina-transport-conversation transport)))
      (cond
       ((and conversation expected (not (equal conversation expected)))
        (mx-machina--transport-fail transport "Backend returned a different conversation ID"))
       ((eq kind 'clean-up)
        (funcall (mx-machina-transport-callback transport) "stopped" "unknown"))
       ((and (eq kind 'error) (not (mx-machina-transport-ready transport)))
        (mx-machina--transport-fail
         transport (or (map-nested-elt event '(:data :message)) "Initialization failed")))
       (t
        (when conversation
          (setf (mx-machina-transport-conversation transport) conversation))
        (when (eq kind 'init-finished)
          (if (and (stringp conversation) (not (string-empty-p conversation)))
              (setf (mx-machina-transport-ready transport) t)
            (mx-machina--transport-fail transport "Backend did not report a conversation ID")))
        (unless (mx-machina-transport-failed transport)
          (let ((ready (mx-machina-transport-ready transport)))
            (funcall
             (mx-machina-transport-callback transport)
             (if ready "live" "starting")
             (if ready
                 (pcase (agent-shell-status :shell-buffer buffer)
                   ('busy "working") ('blocked "approval") (_ "input"))
               "unknown")
             conversation
             (when (eq kind 'error) (map-nested-elt event '(:data :message)))))))))))

(defun mx-machina--transport-event (transport event)
  "Translate EVENT from TRANSPORT into lifecycle and display observations."
  (mx-machina--transport-lifecycle-event transport event)
  (when (and (mx-machina-transport-ready transport)
             (not (mx-machina-transport-stopping transport))
             (not (mx-machina-transport-failed transport)))
    (pcase (map-elt event :event)
      ('input-submitted
       (run-hook-with-args 'mx-machina-backend-event-hook transport 'prompt
                           (list :hash (secure-hash 'sha256 (encode-coding-string
                                        (or (map-nested-elt event '(:data :prompt)) "") 'utf-8-unix)))))
      ('turn-complete
       (run-hook-with-args 'mx-machina-backend-event-hook transport 'turn-ended
                           (when-let* ((reason (map-nested-elt event '(:data :stop-reason))))
                             (unless (equal reason "end_turn") (list :error (format "Turn ended: %s" reason))))))
      ('error
       (run-hook-with-args 'mx-machina-backend-event-hook transport 'turn-ended
                           (list :error (or (map-nested-elt event '(:data :message)) "Agent turn failed"))))
      ('agent-message-chunk
       (when (map-nested-elt event '(:data :text-chunk))
         (run-hook-with-args 'mx-machina-backend-event-hook transport 'message nil)
         (run-hook-with-args 'mx-machina-backend-event-hook transport 'reply-chunk
                             (map-nested-elt event '(:data :text-chunk)))))
      ((or 'init-finished 'init-model 'config-option-update)
       (run-hook-with-args 'mx-machina-backend-event-hook transport 'metadata
                           (mx-machina-backend-metadata transport))))
    (when (memq (map-elt event :event) '(input-submitted turn-complete))
      (run-hook-with-args 'mx-machina-backend-event-hook transport 'metadata
                          (mx-machina-backend-metadata transport)))))

(defun mx-machina-agent-shell-start (profile directory conversation callback)
  "Start PROFILE in DIRECTORY, restoring CONVERSATION when supplied.
Report normalized observations to CALLBACK.  Return a transport object."
  (let* ((config (seq-find
                  (lambda (entry) (equal profile (symbol-name (map-elt entry :identifier))))
                  (mx-machina-backend-configs)))
         (transport (mx-machina--transport-create :callback callback :conversation conversation))
         (default-directory directory)
         (agent-shell-session-strategy 'new))
    (unless config (user-error "Agent profile %s is unavailable" profile))
    ;; ACP creates its client asynchronously, after the launch environment's
    ;; dynamic binding has ended.  Capture discovery variables per run without
    ;; replacing the profile's account environment or mutating its config.
    (let ((environment (seq-filter
                        (lambda (value) (string-prefix-p "EMACS_AGENTS_" value))
                        process-environment))
          (maker (map-elt config :client-maker)))
      (setq config (copy-tree config))
      (setf (map-elt config :client-maker)
            (lambda (buffer)
              (let ((client (funcall maker buffer)))
                (when client
                  (setf (map-elt client :environment-variables)
                        (append environment (map-elt client :environment-variables))))
                client))))
    (setf (mx-machina-transport-buffer transport)
          (save-window-excursion
            (agent-shell-start
             :config config :session-id conversation
             :outgoing-request-decorator
             (lambda (request) (mx-machina--guard-request transport request)))))
    (with-current-buffer (mx-machina-transport-buffer transport)
      (setq mx-machina-agent-shell--transport transport))
    (agent-shell-subscribe-to
     :shell-buffer (mx-machina-transport-buffer transport)
     :on-event (lambda (event) (mx-machina--transport-event transport event)))
    transport))

(provide 'mx-machina-agent-shell)
;;; mx-machina-agent-shell.el ends here
