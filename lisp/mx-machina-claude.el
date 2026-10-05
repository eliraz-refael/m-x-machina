;;; mx-machina-claude.el --- Shared Claude terminal lifecycle -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Conversation identity, account environment and hook observations are shared
;; by terminal adapters.  No terminal output is parsed for agent activity.
;;; Code:
(require 'mx-machina-transport)
(require 'mx-machina-store)
(require 'json)
(require 'map)
(require 'seq)
(declare-function mx-machina--transport-fail "mx-machina-backend")
(defconst mx-machina-claude--hook-script
  (expand-file-name "../scripts/claude-events.py"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Helper invoked by Claude's per-session hooks.")
(defconst mx-machina-claude--events
  '("SessionStart" "UserPromptSubmit" "PreToolUse" "PermissionRequest"
    "PostToolUse" "PostToolUseFailure" "Notification" "Stop" "StopFailure"
    "SessionEnd" "Elicitation" "ElicitationResult" "MessageDisplay" "PostModelSwitch"))
(defvar-local mx-machina-claude--transport nil)
(defvar-local mx-machina-claude--event-file nil)
(defvar-local mx-machina-claude--run-directory nil)
(defvar-local mx-machina-claude--offset 0)
(defvar-local mx-machina-claude--timer nil)
(defvar-local mx-machina-claude--model nil)
(defvar-local mx-machina-claude--turn-active nil)
(defvar-local mx-machina-claude--message-seen nil)
(defvar-local mx-machina-claude--started-at nil)
(defvar-local mx-machina-claude--warned nil)
(defun mx-machina-claude-metadata (transport)
  "Return TRANSPORT's last hook-reported model."
  (with-current-buffer (mx-machina-transport-buffer transport)
    (list :model mx-machina-claude--model)))

(defun mx-machina-claude--uuid ()
  "Return a fresh UUID for a Claude conversation."
  (let ((hex (md5 (format "%s:%s:%s" (current-time) (emacs-pid) (random)))))
    (format "%s-%s-4%s-a%s-%s" (substring hex 0 8) (substring hex 8 12)
            (substring hex 13 16) (substring hex 17 20) (substring hex 20 32))))

(defun mx-machina-claude--write-settings (directory python)
  "Write hook settings in DIRECTORY using PYTHON; return the file name."
  (let* ((file (expand-file-name "settings.json" directory))
         (command (mapconcat #'shell-quote-argument
                             (list python mx-machina-claude--hook-script
                                   (expand-file-name "events.jsonl" directory)) " "))
         (hooks (mapcar (lambda (event)
                          (cons event (vector `((hooks . [((type . "command")
                                                          (command . ,command)
                                                          (timeout . 5))])))))
                        mx-machina-claude--events)))
    (with-temp-file file (insert (json-encode `((hooks . ,hooks)))))
    (set-file-modes file #o600)
    file))

(defun mx-machina-claude--event (event)
  "Apply one Claude hook EVENT in its managed terminal buffer."
  (let* ((transport mx-machina-claude--transport)
         (kind (alist-get 'hook_event_name event))
         (sid (alist-get 'session_id event))
         (expected (mx-machina-transport-conversation transport)))
    (unless (or (mx-machina-transport-stopping transport)
                (mx-machina-transport-failed transport)
                (alist-get 'agent_id event))
      (cond
       ((not (equal sid expected))
        (mx-machina--transport-fail
         transport "Claude changed conversation identity; saved ID retained. Create another agent for a new conversation"))
       (t
        (let ((callback (mx-machina-transport-callback transport)))
          (when (and (equal kind "SessionStart") (not (mx-machina-transport-ready transport)))
            (setf (mx-machina-transport-ready transport) t)
            (setq mx-machina-claude--turn-active nil mx-machina-claude--message-seen nil)
            (funcall callback "live" "input" sid)
            (run-hook-with-args 'mx-machina-backend-event-hook transport 'prompt nil))
          (when (mx-machina-transport-ready transport)
            (pcase kind
              ("UserPromptSubmit"
               (setq mx-machina-claude--turn-active t mx-machina-claude--message-seen nil)
               (funcall callback "live" "working" sid)
               (run-hook-with-args 'mx-machina-backend-event-hook transport 'prompt
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
               (when (and mx-machina-claude--turn-active (eq (alist-get 'has_message event) t))
                 (setq mx-machina-claude--message-seen t)
                 (run-hook-with-args 'mx-machina-backend-event-hook transport 'message nil)))
              ("Stop"
               (funcall callback "live" "input" sid)
               (when (and mx-machina-claude--turn-active
                          (not mx-machina-claude--message-seen)
                          (eq (alist-get 'has_message event) t))
                 (run-hook-with-args 'mx-machina-backend-event-hook transport 'message nil))
               (setq mx-machina-claude--turn-active nil)
               (run-hook-with-args 'mx-machina-backend-event-hook transport 'turn-ended
                                   (list :text (alist-get 'reply event) :request (alist-get 'request_id event))))
              ("StopFailure"
               (setq mx-machina-claude--turn-active nil)
               (funcall callback "live" "input" sid
                        (format "Claude: %s" (or (alist-get 'error event) "turn failed")))
               (run-hook-with-args 'mx-machina-backend-event-hook transport 'turn-ended
                                   (list :error (or (alist-get 'error event) "Turn failed"))))
              ("SessionEnd"
               ;; /clear and /resume can end a conversation without exiting the
               ;; process.  Keep observing so a replacement SessionStart fails.
               (setq mx-machina-claude--turn-active nil)
               (funcall callback "live" "unknown" sid)))
            (let ((model (or (alist-get 'model event)
                             (and (equal kind "PostModelSwitch") (alist-get 'to_model event)))))
              (when (and (stringp model) (not (string-empty-p model)))
                (setq mx-machina-claude--model model)
                (run-hook-with-args 'mx-machina-backend-event-hook transport 'metadata
                                   (list :model model)))))))))))

(defun mx-machina-claude--poll (buffer)
  "Read complete hook records for BUFFER, preserving partial writes."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((transport mx-machina-claude--transport))
        (when (and transport (not (mx-machina-transport-stopping transport))
                   (not (mx-machina-transport-failed transport)))
          (condition-case err
              (when (file-exists-p mx-machina-claude--event-file)
                (let ((file mx-machina-claude--event-file)
                      (offset mx-machina-claude--offset)
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
                  (setq mx-machina-claude--offset offset)
                  (dolist (record (nreverse records)) (mx-machina-claude--event record))))
            (error (mx-machina--transport-fail transport (format "Claude event bridge: %s" (error-message-string err)))))
          (when (and (not (mx-machina-transport-ready transport))
                     (not mx-machina-claude--warned)
                     (> (- (float-time) mx-machina-claude--started-at) 20))
            (setq mx-machina-claude--warned t)
            (funcall (mx-machina-transport-callback transport) "starting" "unknown" nil
                     "Waiting for Claude SessionStart hook; check terminal onboarding, trust, or disabled hooks")))))))

(defun mx-machina-claude--cancel-timer ()
  "Release this terminal's hook poller."
  (when mx-machina-claude--timer (cancel-timer mx-machina-claude--timer))
  (setq mx-machina-claude--timer nil))

(defun mx-machina-claude--cleanup-run ()
  "Remove this run's temporary hook files once its process is gone."
  (when (and mx-machina-claude--run-directory
             (not (process-live-p (get-buffer-process (current-buffer)))))
    (when (file-directory-p mx-machina-claude--run-directory)
      (delete-directory mx-machina-claude--run-directory t))
    (setq mx-machina-claude--run-directory nil)))

(defun mx-machina-claude--exited (process)
  "Record PROCESS exit and release its hook poller."
  (when-let* ((buffer (process-buffer process)) ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (mx-machina-claude--poll buffer)
      (mx-machina-claude--cancel-timer)
      (let ((transport mx-machina-claude--transport))
        (unless (or (mx-machina-transport-stopping transport)
                    (mx-machina-transport-failed transport))
          (if (mx-machina-transport-ready transport)
              (funcall (mx-machina-transport-callback transport) "exited" "unknown")
            (mx-machina--transport-fail transport
                                         "Claude exited before confirming the saved conversation; inspect its terminal"))))
      (mx-machina-claude--cleanup-run))))

(defun mx-machina-claude-stop (transport)
  "Stop TRANSPORT and its poller, retaining the terminal for inspection."
  (setf (mx-machina-transport-stopping transport) t)
  (when (buffer-live-p (mx-machina-transport-buffer transport))
    (with-current-buffer (mx-machina-transport-buffer transport)
      (mx-machina-claude--cancel-timer)
      (when-let* ((process (get-buffer-process (current-buffer))))
        (delete-process process))
      (mx-machina-claude--cleanup-run))))


(defun mx-machina-claude-start (profile config directory conversation callback kind launch setup-hook)
  "Start PROFILE using CONFIG through terminal KIND in DIRECTORY.
Resume CONVERSATION if supplied and report observations to CALLBACK.
LAUNCH receives the command list and a function to initialize buffer state
after its major mode is set.  Run SETUP-HOOK inside the cleanup boundary."
  (let* ((command (map-elt config :command))
         (python (or (executable-find "python3") (user-error "Python 3 is required for Claude status hooks")))
         (process-environment (append (map-elt config :environment) process-environment))
         (default-directory directory)
         (sid (or conversation (mx-machina-claude--uuid)))
         (transport (mx-machina--transport-create :callback callback :conversation sid))
         (parent (expand-file-name "terminal-runs/" mx-machina-directory)))
    (unless (and command (executable-find (car command)))
      (user-error "Claude executable unavailable for %s" profile))
    (unless (file-readable-p mx-machina-claude--hook-script) (user-error "Claude hook helper is missing"))
    (make-directory parent t)
    (let* ((run-directory (make-temp-file (expand-file-name "run-" parent) t))
           (buffer (generate-new-buffer (format "*Agent %s %s*" profile (substring sid 0 8)))))
      (set-file-modes run-directory #o700)
      (setf (mx-machina-transport-buffer transport) buffer)
      (condition-case err
          (with-current-buffer buffer
            (let ((settings (mx-machina-claude--write-settings run-directory python)))
              (funcall launch
                       (append command (list "--settings" settings
                                             (if conversation "--resume" "--session-id") sid))
                       (lambda ()
                         (setq-local mx-machina--backend-kind kind
                                     mx-machina-claude--transport transport
                                     mx-machina-claude--run-directory run-directory
                                     mx-machina-claude--event-file (expand-file-name "events.jsonl" run-directory)
                                     mx-machina-claude--started-at (float-time))
                         (add-hook 'kill-buffer-hook #'mx-machina-claude--cancel-timer nil t))))
            (funcall callback "starting" "unknown" sid)
            (setq mx-machina-claude--timer (run-at-time 0.2 0.2 #'mx-machina-claude--poll buffer))
            (run-hooks setup-hook))
        ((error quit)
         (mx-machina-claude-stop transport)
         (when (file-directory-p run-directory) (delete-directory run-directory t))
         (signal (car err) (cdr err))))
      transport)))

(provide 'mx-machina-claude)
;;; mx-machina-claude.el ends here
