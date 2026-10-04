;;; emacs-agents-diagnostics.el --- Read-only session diagnosis -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Inspect saved metadata and local runtime state without starting, reconciling,
;; migrating or polling an agent.  Shareable reports exclude raw errors, command
;; arguments, environments and conversation contents.
;;; Code:
(require 'emacs-agents)
(require 'map)
(require 'seq)
(defvar-local emacs-agents-diagnostics--id nil)
(defvar-local emacs-agents-diagnostics--source nil)
(defvar-local emacs-agents-diagnostics--summary nil)

(defun emacs-agents-diagnostics--sessions ()
  "Read saved records without opening the manager or recovering process state."
  (let* ((file (expand-file-name "sessions.sqlite" emacs-agents-directory))
         (owned emacs-agents--db)
         (db (or owned
                 (progn
                   (unless (file-exists-p file) (user-error "No agent registry exists yet"))
                   (sqlite-open file)))))
    (unwind-protect
        (progn
          ;; Compatible with SQLite-enabled Emacs versions without an explicit
          ;; read-only sqlite-open argument.  Never set this on the manager's DB.
          (unless owned (sqlite-execute db "PRAGMA query_only=ON"))
          (unless (= 3 (caar (sqlite-select db "PRAGMA user_version")))
            (user-error "Open the agent manager to handle this registry schema before diagnosing it"))
          (mapcar #'emacs-agents--session-from-row
                  (sqlite-select db (concat "SELECT " emacs-agents--session-columns " FROM sessions ORDER BY rowid"))))
      (unless owned (sqlite-close db)))))

(defun emacs-agents-diagnostics--read-id ()
  "Read an agent ID without changing registry observations."
  (or emacs-agents-diagnostics--id
      (and (derived-mode-p 'emacs-agents-mode) (tabulated-list-get-id))
      (and (derived-mode-p 'emacs-agents-sidebar-mode 'emacs-agents-board-mode) (get-text-property (point) 'emacs-agents-id))
      emacs-agents--managed-id
      (let ((choices (mapcar (lambda (session)
                              (cons (format "%s/%s [%s]%s" (emacs-agents-session-folder session)
                                            (emacs-agents-session-name session)
                                            (substring (emacs-agents-session-id session) 0 8)
                                            (if (emacs-agents-archived-p session) " (archived)" ""))
                                    (emacs-agents-session-id session)))
                            (emacs-agents-diagnostics--sessions))))
        (unless choices (user-error "No saved agents to diagnose"))
        (cdr (assoc (completing-read "Diagnose agent: " choices nil t) choices)))))

(defun emacs-agents-diagnostics--failure-kind (error-text)
  "Classify ERROR-TEXT without returning arbitrary backend text."
  (let ((case-fold-search t))
    (cond
     ((not (and (stringp error-text) (not (string-empty-p error-text)))) nil)
     ((string-match-p "auth\\|credential\\|unauthorized\\|login\\|401" error-text) 'authentication)
     ((string-match-p "unsupported resume\\|resume.*not supported\\|does not support.*resum" error-text) 'unsupported)
     ((string-match-p "resume failed" error-text) 'resume)
     ((string-match-p "history\\|conversation.*not found\\|cannot find.*conversation" error-text) 'history)
     ((string-match-p "identity\\|different conversation\\|replacement" error-text) 'identity)
     ((string-match-p "SessionStart\\|before confirming" error-text) 'unconfirmed)
     ((string-match-p "event bridge" error-text) 'bridge)
     (t 'other))))

(defun emacs-agents-diagnostics--failure (error-text)
  "Describe ERROR-TEXT without exposing arbitrary backend text."
  (pcase (emacs-agents-diagnostics--failure-kind error-text)
    ('authentication "Authentication-related failure; check the selected account in its backend")
    ('unsupported "Unsupported resume; this backend did not offer loading or resuming saved sessions")
    ('history "Saved history unavailable; retain the saved ID while investigating")
    ('resume "Resume failed; replacement was blocked and the original ID was retained")
    ('identity "Conversation identity failure; replacement was blocked")
    ('unconfirmed "SessionStart was not confirmed; inspect terminal onboarding, trust and hooks")
    ('bridge "Claude event bridge failed; status observations stopped")
    ('other "Backend/startup failure recorded; inspect the local error detail")
    (_ "None recorded")))

(defun emacs-agents-diagnostics--guidance (session config config-failed)
  "Return actionable local recovery steps for SESSION and its CONFIG.
CONFIG-FAILED means profile definitions could not be inspected."
  (let ((steps
         (cond
          (config-failed
           (list "Fix the error in your profile definitions, reload them, then press g. No profile was selected automatically."))
          ((not config)
           (list (format "Restore the original definition with identifier %s in emacs-agents-eat-profiles, emacs-agents-vterm-profiles, or agent-shell-agent-configs. Reload that configuration, then press g."
                         (emacs-agents-session-profile session)))))))
    (when-let* ((step
                 (pcase (emacs-agents-diagnostics--failure-kind (emacs-agents-session-error session))
                   ('authentication "Sign in again using the original account and the saved profile's authentication configuration. For Claude terminals, keep its original CLAUDE_CONFIG_DIR; for ACP, check that profile's authentication settings. Then stop the failed run before retrying.")
                   ('unsupported "Restore a backend/version that supports loading or resuming this saved conversation. Repeated retries cannot add missing resume support. To start over, create a separate agent with n in the sidebar; retain this record.")
                   ('history "Check the original account, backend history and working directory. Restore history from your own backup if available. W repairs the saved checkout association, but does not move backend history. If history cannot be recovered, use n in the sidebar to create a separate agent.")
                   ((or 'resume 'identity) "Inspect the local error and retained backend buffer. Check the original account, history and working directory; the backend may have rejected this saved ID. Replacement requests stay blocked. Use a separate new agent if you intentionally want a fresh conversation.")
                   ('unconfirmed "Inspect the retained terminal for login, trust, hook or missing-history messages. No SessionStart alone does not identify which of these failed. Complete setup in the original account, then stop the run before retrying.")
                   ('bridge "Check the hook helper and Python dependency above. Inspect the retained terminal, then stop the failed run before retrying.")
                   ('other "Inspect the local failure detail and retained backend buffer, fix the reported configuration or dependency problem, then stop the failed run before retrying."))))
      (setq steps (append steps (list step))))
    (append steps
            (list "Profile/account verification: this registry stores a profile identifier, not a verified account identity. Restore the original backend and account configuration. Matching display names are insufficient for reassignment; automatic profile replacement is unavailable.")
            (list (cond
                   ((emacs-agents-archived-p session) "Restore this archived record from A before retrying.")
                   ((not (emacs-agents-session-conversation session))
                    (if (emacs-agents-session-run session)
                        "No conversation ID was captured. Retry is disabled; inspect the retained buffer or create a separate agent explicitly."
                      "This agent has not created a conversation yet. Open it from the sidebar for its first start; R only retries saved conversations."))
                   (t "After repair, stop any remaining process with x in the sidebar. R here reviews and retries the saved conversation with its existing profile. It sends no prompt and creates no replacement conversation."))))))

(defun emacs-agents-diagnostics--collect (id)
  "Collect local checks for ID as (:session SESSION :checks ROWS).
Each row is (LABEL SEVERITY DETAIL).  Do not launch or poll anything."
  (let* ((session (or (seq-find (lambda (s) (equal id (emacs-agents-session-id s)))
                                (emacs-agents-diagnostics--sessions))
                      (user-error "This agent record no longer exists")))
         (profile (emacs-agents-session-profile session))
         (directory (emacs-agents-session-directory session))
         (entry (gethash id emacs-agents--running))
         (transport (cdr entry))
         (buffer (and transport (emacs-agents-transport-buffer transport)))
         (process (and transport (emacs-agents-backend-process transport)))
         (live (and process (process-live-p process)))
         config config-failed checks)
    (condition-case nil
        (setq config (seq-find (lambda (c) (equal profile (symbol-name (map-elt c :identifier))))
                               (emacs-agents-backend-configs)))
      (error (setq config-failed t)))
    (cl-labels ((row (label severity detail) (push (list label severity detail) checks))
                (library (name)
                  (row (format "Dependency: %s" name)
                       (if (or (featurep name) (locate-library (symbol-name name))) 'ok 'blocked)
                       (if (or (featurep name) (locate-library (symbol-name name)))
                           "Available locally (not a compatibility or authentication check)"
                         "Not available; install this dependency before launching"))))
      (let* ((kind (or (map-elt config :interface)
                       (and (buffer-live-p buffer) (buffer-local-value 'emacs-agents--backend-kind buffer))))
             (command (or (map-elt config :diagnostic-command)
                          (and (memq kind '(eat vterm)) (listp (map-elt config :command))
                               (car (map-elt config :command)))
                          (and process (car (process-command process))))))
        (unless (and (stringp command) (not (string-empty-p command)))
          (setq command nil))
        (row "Profile" (if config 'ok 'blocked)
             (cond (config (concat profile " — configured"))
                   (config-failed "Configuration inspection failed; check your profile definitions")
                   (t (concat profile " — unavailable; restore this profile in your configuration"))))
        (row "Interface" (if kind 'info 'warning) (if kind (symbol-name kind) "Unknown while the saved profile is unavailable"))
        (row "Executable" (cond ((null command) 'warning) ((executable-find command) 'ok) (t 'blocked))
             (cond ((null command) "Not declared by this profile; its client factory was not invoked")
                   ((executable-find command) (format "%s — found" command))
                   (t (format "%s — missing from the launch search path" command))))
        (pcase kind
          ('eat (library 'eat))
          ('vterm (library 'vterm) (library 'vterm-module))
          ('agent-shell (dolist (name '(agent-shell acp shell-maker)) (library name))))
        (when (memq kind '(eat vterm))
          (row "Dependency: Python 3" (if (executable-find "python3") 'ok 'blocked)
               (if (executable-find "python3") "Available" "Missing; Claude status hooks require Python 3"))
          (row "Hook helper" (if (file-readable-p emacs-agents-claude--hook-script) 'ok 'blocked)
               (if (file-readable-p emacs-agents-claude--hook-script) "Available" "Missing; reinstall the package's scripts directory")))
        (row "Recorded worktree" 'info directory)
        (row "Recorded branch" 'info (emacs-agents-session-branch session))
        (cond
         ((file-remote-p directory) (row "Worktree" 'blocked "Remote worktrees are unsupported"))
         ((not (file-directory-p directory)) (row "Worktree" 'blocked "Directory missing; W associates a relocated checkout, or restore its recorded location"))
         ((not (executable-find "git")) (row "Git" 'blocked "Git is missing; actual worktree and branch could not be checked"))
         (t
          (condition-case nil
              (pcase-let ((`(,actual ,branch) (emacs-agents--worktree directory)))
                (row "Actual worktree" (if (equal actual directory) 'ok 'blocked) actual)
                (row "Actual branch" (if (equal branch (emacs-agents-session-branch session)) 'ok 'blocked) branch)
                (unless (equal (list actual branch) (list directory (emacs-agents-session-branch session)))
                  (row "Worktree mismatch" 'blocked "Recorded and actual checkout differ; W reviews the association, or restore the recorded checkout")))
            (error (row "Worktree" 'blocked "Directory exists, but Git could not inspect a valid checkout")))))
        (row "Saved process state" 'info (emacs-agents-session-status session))
        (row "Run" 'info (or (emacs-agents-session-run session) "Not launched"))
        (row "Activity" 'info (emacs-agents-session-activity session))
        (row "Process now" (if live 'ok 'info)
             (cond (live (format "Running (PID %s)" (process-id process)))
                   (process (format "Exited/not live (%s, exit status %s)" (process-status process) (process-exit-status process)))
                   ((equal (emacs-agents-session-status session) "exited") "Exited; open the agent explicitly to resume")
                   (t "No tracked live process in this Emacs")))
        (when (and (not live) (member (emacs-agents-session-status session) '("live" "starting")))
          (row "Observation" 'warning "Saved live state has no live process here; diagnostics do not reconcile it"))
        (when (emacs-agents-archived-p session)
          (row "Archive" 'blocked "Archived; restore the record before starting it"))
        (row "Conversation" (if (or (emacs-agents-session-conversation session)
                                     (not (emacs-agents-session-run session))) 'info 'blocked)
             (or (emacs-agents-session-conversation session)
                 (if (emacs-agents-session-run session)
                     "Missing after a previous launch; automatic replacement is blocked"
                   "Not created yet; first explicit start will create it")))
        (row "Latest failure" (if (emacs-agents-session-error session) 'warning 'info)
             (emacs-agents-diagnostics--failure (emacs-agents-session-error session)))
        (if (not (memq kind '(eat vterm)))
            (row "Status bridge" 'info
                 (if (eq kind 'agent-shell) "Uses ACP events; Claude terminal hooks do not apply"
                   "Cannot determine the status interface without the saved profile"))
          (if (not (and live (buffer-live-p buffer)))
              (row "Status bridge" 'info "Inactive while the terminal process is stopped")
            (with-current-buffer buffer
              (let* ((ready (emacs-agents-transport-ready transport))
                     (elapsed (and emacs-agents-claude--started-at
                                   (max 0 (- (float-time) emacs-agents-claude--started-at))))
                     (polling (and emacs-agents-claude--timer (memq emacs-agents-claude--timer timer-list)))
                     (file emacs-agents-claude--event-file)
                     (readable (and file (file-readable-p file))))
                (row "SessionStart" (cond (ready 'ok) ((and elapsed (> elapsed 20)) 'blocked) (t 'warning))
                     (if ready "Confirmed for this run"
                       (format "Not received%s; inspect terminal login/trust prompts and disabled hooks"
                               (if elapsed (format " after %.0fs" elapsed) ""))))
                (row "Event poller" (if polling 'ok 'warning)
                     (if polling "Active (diagnostics did not poll it)" "Inactive; status updates will not arrive"))
                (row "Event file" (if readable 'ok 'warning)
                     (if readable (format "Readable; %d bytes consumed" emacs-agents-claude--offset)
                       "Not readable or not created yet; hooks may not have written an event")))))))
      (list :session session :checks (nreverse checks)
            :guidance (emacs-agents-diagnostics--guidance session config config-failed)))))

(defun emacs-agents-diagnostics--text (report)
  "Format REPORT for sharing, excluding raw errors and backend payloads."
  (let ((session (plist-get report :session)))
    (concat "Agent diagnostics\n"
            (format "Name: %s\nSession: %s\nEmacs: %s\n\n"
                    (emacs-agents-session-name session) (emacs-agents-session-id session) emacs-version)
            (format "Folder: %s\nProject: %s\nModel: %s\nUnread: %s\nArchived: %s\n\n"
                    (if (string-empty-p (emacs-agents-session-folder session)) "root"
                      (emacs-agents-session-folder session))
                    (or (emacs-agents-session-project session) "Not recorded")
                    (or (emacs-agents-session-model session) "Not reported")
                    (if (emacs-agents-unread-p session) "yes" "no")
                    (if (emacs-agents-archived-p session) "yes" "no"))
            (mapconcat (lambda (row) (format "[%s] %s: %s" (upcase (symbol-name (nth 1 row))) (car row) (nth 2 row)))
                       (plist-get report :checks) "\n")
            "\n\nRecovery steps\n"
            (mapconcat (lambda (step) (concat "• " step)) (plist-get report :guidance) "\n\n")
            "\n\nLocal snapshot only; provider authentication and saved history were not contacted.\n"
            "Includes local paths and IDs. Excludes raw errors, command arguments, environment values and conversation text.\n")))

(defun emacs-agents-diagnostics-refresh ()
  "Refresh the diagnostic snapshot without changing agent state."
  (interactive)
  (let* ((report (emacs-agents-diagnostics--collect emacs-agents-diagnostics--id))
         (summary (emacs-agents-diagnostics--text report))
         (failure (emacs-agents-session-error (plist-get report :session)))
         (position (point))
         (inhibit-read-only t))
    (erase-buffer)
    (insert summary)
    (when failure (insert "\nLocal failure detail (omitted by w / copy summary):\n" failure "\n"))
    (goto-char (point-min))
    (while (re-search-forward "^\\[\\(OK\\|BLOCKED\\|WARNING\\)\\]" nil t)
      (add-face-text-property (match-beginning 0) (match-end 0)
                             (pcase (match-string 1) ("OK" 'success) ("BLOCKED" 'error) (_ 'warning))))
    (setq emacs-agents-diagnostics--summary summary)
    (goto-char (min position (point-max)))))

(defun emacs-agents-diagnostics-copy ()
  "Copy the displayed diagnostic summary, excluding the local raw error detail."
  (interactive)
  (unless emacs-agents-diagnostics--summary (user-error "No diagnostic snapshot to copy"))
  (kill-new emacs-agents-diagnostics--summary)
  (message "Copied diagnostics (includes paths and IDs; excludes raw error details and backend payloads)"))

(defun emacs-agents-diagnostics-return ()
  "Return to the buffer shown before these diagnostics."
  (interactive)
  (if (buffer-live-p emacs-agents-diagnostics--source)
      (switch-to-buffer emacs-agents-diagnostics--source)
    (quit-window)))

(defvar emacs-agents-diagnostics-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'emacs-agents-diagnostics-refresh)
    (define-key map (kbd "w") #'emacs-agents-diagnostics-copy)
    (define-key map (kbd "R") #'emacs-agents-retry)
    (define-key map (kbd "W") #'emacs-agents-rebind-worktree)
    (define-key map (kbd "q") #'emacs-agents-diagnostics-return)
    (define-key map (kbd "?") #'emacs-agents-actions)
    map))
(define-derived-mode emacs-agents-diagnostics-mode special-mode "Agent Diagnostics"
  "A read-only local snapshot of agent readiness and runtime health."
  (setq-local truncate-lines nil header-line-format " Diagnostics · g refresh · w copy · W worktree · R retry · q return")
  (visual-line-mode 1))

;;;###autoload
(defun emacs-agents-diagnostics (id)
  "Inspect agent ID without launching, repairing or acknowledging output."
  (interactive (list (emacs-agents-diagnostics--read-id)))
  (let ((buffer (get-buffer-create (format "*Agent diagnostics %s*" (substring id 0 8)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'emacs-agents-diagnostics-mode) (emacs-agents-diagnostics-mode))
      (setq emacs-agents-diagnostics--id id)
      (emacs-agents-diagnostics-refresh))
    (emacs-agents--select-main-window)
    (unless (eq (current-buffer) buffer)
      (let ((source (current-buffer)))
        (switch-to-buffer buffer)
        (setq emacs-agents-diagnostics--source source)))
    buffer))

(provide 'emacs-agents-diagnostics)
;;; emacs-agents-diagnostics.el ends here
