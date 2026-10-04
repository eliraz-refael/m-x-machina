;;; emacs-agents-claude.el --- Shared Claude terminal lifecycle -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Conversation identity, account environment and hook observations are shared
;; by terminal adapters.  No terminal output is parsed for agent activity.
;;; Code:
(require 'emacs-agents-transport)
(require 'emacs-agents-store)
(require 'json)
(require 'map)
(require 'seq)
(declare-function emacs-agents--transport-fail "emacs-agents-backend")
(defconst emacs-agents-claude--hook-script
  (expand-file-name "../scripts/claude-events.py"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Helper invoked by Claude's per-session hooks.")
(defconst emacs-agents-claude--events
  '("SessionStart" "UserPromptSubmit" "PreToolUse" "PermissionRequest"
    "PostToolUse" "PostToolUseFailure" "Notification" "Stop" "StopFailure"
    "SessionEnd" "Elicitation" "ElicitationResult" "MessageDisplay" "PostModelSwitch"))
(defvar-local emacs-agents-claude--transport nil)
(defvar-local emacs-agents-claude--event-file nil)
(defvar-local emacs-agents-claude--run-directory nil)
(defvar-local emacs-agents-claude--offset 0)
(defvar-local emacs-agents-claude--timer nil)
(defvar-local emacs-agents-claude--model nil)
(defvar-local emacs-agents-claude--turn-active nil)
(defvar-local emacs-agents-claude--message-seen nil)
(defvar-local emacs-agents-claude--started-at nil)
(defvar-local emacs-agents-claude--warned nil)
(defun emacs-agents-claude-metadata (transport)
  "Return TRANSPORT's last hook-reported model."
  (with-current-buffer (emacs-agents-transport-buffer transport)
    (list :model emacs-agents-claude--model)))

(defun emacs-agents-claude--uuid ()
  "Return a fresh UUID for a Claude conversation."
  (let ((hex (md5 (format "%s:%s:%s" (current-time) (emacs-pid) (random)))))
    (format "%s-%s-4%s-a%s-%s" (substring hex 0 8) (substring hex 8 12)
            (substring hex 13 16) (substring hex 17 20) (substring hex 20 32))))

(defun emacs-agents-claude--write-settings (directory python)
  "Write hook settings in DIRECTORY using PYTHON; return the file name."
  (let* ((file (expand-file-name "settings.json" directory))
         (command (mapconcat #'shell-quote-argument
                             (list python emacs-agents-claude--hook-script
                                   (expand-file-name "events.jsonl" directory)) " "))
         (hooks (mapcar (lambda (event)
                          (cons event (vector `((hooks . [((type . "command")
                                                          (command . ,command)
                                                          (timeout . 5))])))))
                        emacs-agents-claude--events)))
    (with-temp-file file (insert (json-encode `((hooks . ,hooks)))))
    (set-file-modes file #o600)
    file))

(defun emacs-agents-claude--event (event)
  "Apply one Claude hook EVENT in its managed terminal buffer."
  (let* ((transport emacs-agents-claude--transport)
         (kind (alist-get 'hook_event_name event))
         (sid (alist-get 'session_id event))
         (expected (emacs-agents-transport-conversation transport)))
    (unless (or (emacs-agents-transport-stopping transport)
                (emacs-agents-transport-failed transport)
                (alist-get 'agent_id event))
      (cond
       ((not (equal sid expected))
        (emacs-agents--transport-fail
         transport "Claude changed conversation identity; saved ID retained. Create another agent for a new conversation"))
       (t
        (let ((callback (emacs-agents-transport-callback transport)))
          (when (and (equal kind "SessionStart") (not (emacs-agents-transport-ready transport)))
            (setf (emacs-agents-transport-ready transport) t)
            (setq emacs-agents-claude--turn-active nil emacs-agents-claude--message-seen nil)
            (funcall callback "live" "input" sid)
            (run-hook-with-args 'emacs-agents-backend-event-hook transport 'prompt nil))
          (when (emacs-agents-transport-ready transport)
            (pcase kind
              ("UserPromptSubmit"
               (setq emacs-agents-claude--turn-active t emacs-agents-claude--message-seen nil)
               (funcall callback "live" "working" sid)
               (run-hook-with-args 'emacs-agents-backend-event-hook transport 'prompt
                                   (list :hash (alist-get 'prompt_hash event))))
              ("PreToolUse"
               (funcall callback "live"
                        (if (member (alist-get 'tool_name event) '("AskUserQuestion" "ExitPlanMode"))
                            "approval" "working") sid))
              ((or "PermissionRequest" "Elicitation") (funcall callback "live" "approval" sid))
              ((or "PostToolUse" "PostToolUseFailure" "ElicitationResult")
               (funcall callback "live" "working" sid))
              ("Notification"
               (pcase (alist-get 'notification_type event)
                 ((or "permission_prompt" "elicitation_dialog" "elicitation_url_dialog" "agent_needs_input")
                  (funcall callback "live" "approval" sid))
                 ("idle_prompt" (funcall callback "live" "input" sid))))
              ("MessageDisplay"
               ;; History redraws have no active submitted turn in this run.
               (when (and emacs-agents-claude--turn-active (eq (alist-get 'has_message event) t))
                 (setq emacs-agents-claude--message-seen t)
                 (run-hook-with-args 'emacs-agents-backend-event-hook transport 'message nil)))
              ("Stop"
               (funcall callback "live" "input" sid)
               (when (and emacs-agents-claude--turn-active
                          (not emacs-agents-claude--message-seen)
                          (eq (alist-get 'has_message event) t))
                 (run-hook-with-args 'emacs-agents-backend-event-hook transport 'message nil))
               (setq emacs-agents-claude--turn-active nil)
               (run-hook-with-args 'emacs-agents-backend-event-hook transport 'turn-ended
                                   (list :text (alist-get 'reply event) :request (alist-get 'request_id event))))
              ("StopFailure"
               (setq emacs-agents-claude--turn-active nil)
               (funcall callback "live" "input" sid
                        (format "Claude: %s" (or (alist-get 'error event) "turn failed")))
               (run-hook-with-args 'emacs-agents-backend-event-hook transport 'turn-ended
                                   (list :error (or (alist-get 'error event) "Turn failed"))))
              ("SessionEnd"
               ;; /clear and /resume can end a conversation without exiting the
               ;; process.  Keep observing so a replacement SessionStart fails.
               (setq emacs-agents-claude--turn-active nil)
               (funcall callback "live" "unknown" sid)))
            (let ((model (or (alist-get 'model event)
                             (and (equal kind "PostModelSwitch") (alist-get 'to_model event)))))
              (when (and (stringp model) (not (string-empty-p model)))
                (setq emacs-agents-claude--model model)
                (run-hook-with-args 'emacs-agents-backend-event-hook transport 'metadata
                                   (list :model model)))))))))))

(defun emacs-agents-claude--poll (buffer)
  "Read complete hook records for BUFFER, preserving partial writes."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((transport emacs-agents-claude--transport))
        (when (and transport (not (emacs-agents-transport-stopping transport))
                   (not (emacs-agents-transport-failed transport)))
          (condition-case err
              (when (file-exists-p emacs-agents-claude--event-file)
                (let ((file emacs-agents-claude--event-file)
                      (offset emacs-agents-claude--offset)
                      records)
                  (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally file nil offset)
                    (goto-char (point-min))
                    (while (search-forward "\n" nil t)
                      (push (json-parse-string
                             (decode-coding-string (buffer-substring-no-properties
                                                    (point-min) (1- (point))) 'utf-8)
                             :object-type 'alist :false-object nil :null-object nil) records)
                      (setq offset (+ offset (- (point) (point-min))))
                      (delete-region (point-min) (point))))
                  (setq emacs-agents-claude--offset offset)
                  (dolist (record (nreverse records)) (emacs-agents-claude--event record))))
            (error (emacs-agents--transport-fail transport (format "Claude event bridge: %s" (error-message-string err)))))
          (when (and (not (emacs-agents-transport-ready transport))
                     (not emacs-agents-claude--warned)
                     (> (- (float-time) emacs-agents-claude--started-at) 20))
            (setq emacs-agents-claude--warned t)
            (funcall (emacs-agents-transport-callback transport) "starting" "unknown" nil
                     "Waiting for Claude SessionStart hook; check terminal onboarding, trust, or disabled hooks")))))))

(defun emacs-agents-claude--cancel-timer ()
  "Release this terminal's hook poller."
  (when emacs-agents-claude--timer (cancel-timer emacs-agents-claude--timer))
  (setq emacs-agents-claude--timer nil))

(defun emacs-agents-claude--cleanup-run ()
  "Remove this run's temporary hook files once its process is gone."
  (when (and emacs-agents-claude--run-directory
             (not (process-live-p (get-buffer-process (current-buffer)))))
    (when (file-directory-p emacs-agents-claude--run-directory)
      (delete-directory emacs-agents-claude--run-directory t))
    (setq emacs-agents-claude--run-directory nil)))

(defun emacs-agents-claude--exited (process)
  "Record PROCESS exit and release its hook poller."
  (when-let* ((buffer (process-buffer process)) ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (emacs-agents-claude--poll buffer)
      (emacs-agents-claude--cancel-timer)
      (let ((transport emacs-agents-claude--transport))
        (unless (or (emacs-agents-transport-stopping transport)
                    (emacs-agents-transport-failed transport))
          (if (emacs-agents-transport-ready transport)
              (funcall (emacs-agents-transport-callback transport) "exited" "unknown")
            (emacs-agents--transport-fail transport
                                         "Claude exited before confirming the saved conversation; inspect its terminal"))))
      (emacs-agents-claude--cleanup-run))))

(defun emacs-agents-claude-stop (transport)
  "Stop TRANSPORT and its poller, retaining the terminal for inspection."
  (setf (emacs-agents-transport-stopping transport) t)
  (when (buffer-live-p (emacs-agents-transport-buffer transport))
    (with-current-buffer (emacs-agents-transport-buffer transport)
      (emacs-agents-claude--cancel-timer)
      (when-let* ((process (get-buffer-process (current-buffer))))
        (delete-process process))
      (emacs-agents-claude--cleanup-run))))


(defun emacs-agents-claude-start (profile config directory conversation callback kind launch setup-hook)
  "Start PROFILE using CONFIG through terminal KIND in DIRECTORY.
Resume CONVERSATION if supplied and report observations to CALLBACK.
LAUNCH receives the command list and a function to initialize buffer state
after its major mode is set.  Run SETUP-HOOK inside the cleanup boundary."
  (let* ((command (map-elt config :command))
         (python (or (executable-find "python3") (user-error "Python 3 is required for Claude status hooks")))
         (process-environment (append (map-elt config :environment) process-environment))
         (default-directory directory)
         (sid (or conversation (emacs-agents-claude--uuid)))
         (transport (emacs-agents--transport-create :callback callback :conversation sid))
         (parent (expand-file-name "terminal-runs/" emacs-agents-directory)))
    (unless (and command (executable-find (car command)))
      (user-error "Claude executable unavailable for %s" profile))
    (unless (file-readable-p emacs-agents-claude--hook-script) (user-error "Claude hook helper is missing"))
    (make-directory parent t)
    (let* ((run-directory (make-temp-file (expand-file-name "run-" parent) t))
           (buffer (generate-new-buffer (format "*Agent %s %s*" profile (substring sid 0 8)))))
      (set-file-modes run-directory #o700)
      (setf (emacs-agents-transport-buffer transport) buffer)
      (condition-case err
          (with-current-buffer buffer
            (let ((settings (emacs-agents-claude--write-settings run-directory python)))
              (funcall launch
                       (append command (list "--settings" settings
                                             (if conversation "--resume" "--session-id") sid))
                       (lambda ()
                         (setq-local emacs-agents--backend-kind kind
                                     emacs-agents-claude--transport transport
                                     emacs-agents-claude--run-directory run-directory
                                     emacs-agents-claude--event-file (expand-file-name "events.jsonl" run-directory)
                                     emacs-agents-claude--started-at (float-time))
                         (add-hook 'kill-buffer-hook #'emacs-agents-claude--cancel-timer nil t))))
            (funcall callback "starting" "unknown" sid)
            (setq emacs-agents-claude--timer (run-at-time 0.2 0.2 #'emacs-agents-claude--poll buffer))
            (run-hooks setup-hook))
        ((error quit)
         (emacs-agents-claude-stop transport)
         (when (file-directory-p run-directory) (delete-directory run-directory t))
         (signal (car err) (cdr err))))
      transport)))

(provide 'emacs-agents-claude)
;;; emacs-agents-claude.el ends here
