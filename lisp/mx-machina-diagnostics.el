;;; mx-machina-diagnostics.el --- Read-only session diagnosis -*- lexical-binding: t; -*-

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
;; Inspect saved metadata and local runtime state without starting, reconciling,
;; migrating or polling an agent.  Shareable reports exclude raw errors, command
;; arguments, environments and conversation contents.
;;; Code:
(require 'mx-machina)
(require 'map)
(require 'seq)
(defvar-local mx-machina-diagnostics--id nil)
(defvar-local mx-machina-diagnostics--source nil)
(defvar-local mx-machina-diagnostics--summary nil)

(defun mx-machina-diagnostics--sessions ()
  "Read saved records without opening the manager or recovering process state."
  (let* ((file (expand-file-name "sessions.sqlite" mx-machina-directory))
         (owned mx-machina--db)
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
          (mapcar #'mx-machina--session-from-row
                  (sqlite-select db (concat "SELECT " mx-machina--session-columns " FROM sessions ORDER BY rowid"))))
      (unless owned (sqlite-close db)))))

(defun mx-machina-diagnostics--read-id ()
  "Read an agent ID without changing registry observations."
  (or mx-machina-diagnostics--id
      (and (derived-mode-p 'mx-machina-mode) (tabulated-list-get-id))
      (and (derived-mode-p 'mx-machina-sidebar-mode 'mx-machina-board-mode) (get-text-property (point) 'mx-machina-id))
      mx-machina--managed-id
      (let ((choices (mapcar (lambda (session)
                              (cons (format "%s/%s [%s]%s" (mx-machina-session-folder session)
                                            (mx-machina-session-name session)
                                            (substring (mx-machina-session-id session) 0 8)
                                            (if (mx-machina-archived-p session) " (archived)" ""))
                                    (mx-machina-session-id session)))
                            (mx-machina-diagnostics--sessions))))
        (unless choices (user-error "No saved agents to diagnose"))
        (cdr (assoc (completing-read "Diagnose agent: " choices nil t) choices)))))

(defun mx-machina-diagnostics--failure-kind (error-text)
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

(defun mx-machina-diagnostics--failure (error-text)
  "Describe ERROR-TEXT without exposing arbitrary backend text."
  (pcase (mx-machina-diagnostics--failure-kind error-text)
    ('authentication "Authentication-related failure; check the selected account in its backend")
    ('unsupported "Unsupported resume; this backend did not offer loading or resuming saved sessions")
    ('history "Saved history unavailable; retain the saved ID while investigating")
    ('resume "Resume failed; replacement was blocked and the original ID was retained")
    ('identity "Conversation identity failure; replacement was blocked")
    ('unconfirmed "SessionStart was not confirmed; inspect terminal onboarding, trust and hooks")
    ('bridge "Claude event bridge failed; status observations stopped")
    ('other "Backend/startup failure recorded; inspect the local error detail")
    (_ "None recorded")))

(defun mx-machina-diagnostics--guidance (session config config-failed)
  "Return actionable local recovery steps for SESSION and its CONFIG.
CONFIG-FAILED means profile definitions could not be inspected."
  (let ((steps
         (cond
          (config-failed
           (list "Fix the error in your profile definitions, reload them, then press g. No profile was selected automatically."))
          ((not config)
           (list (format "Restore the original definition with identifier %s in mx-machina-eat-profiles, mx-machina-vterm-profiles, or agent-shell-agent-configs. Reload that configuration, then press g."
                         (mx-machina-session-profile session)))))))
    (when-let* ((step
                 (pcase (mx-machina-diagnostics--failure-kind (mx-machina-session-error session))
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
                   ((mx-machina-archived-p session) "Restore this archived record from A before retrying.")
                   ((not (mx-machina-session-conversation session))
                    (if (mx-machina-session-run session)
                        "No conversation ID was captured. Retry is disabled; inspect the retained buffer or create a separate agent explicitly."
                      "This agent has not created a conversation yet. Open it from the sidebar for its first start; R only retries saved conversations."))
                   (t "After repair, stop any remaining process with x in the sidebar. R here reviews and retries the saved conversation with its existing profile. It sends no prompt and creates no replacement conversation."))))))

(defun mx-machina-diagnostics--collect (id)
  "Collect local checks for ID as (:session SESSION :checks ROWS).
Each row is (LABEL SEVERITY DETAIL).  Do not launch or poll anything."
  (let* ((session (or (seq-find (lambda (s) (equal id (mx-machina-session-id s)))
                                (mx-machina-diagnostics--sessions))
                      (user-error "This agent record no longer exists")))
         (profile (mx-machina-session-profile session))
         (directory (mx-machina-session-directory session))
         (entry (gethash id mx-machina--running))
         (transport (cdr entry))
         (buffer (and transport (mx-machina-transport-buffer transport)))
         (process (and transport (mx-machina-backend-process transport)))
         (live (and process (process-live-p process)))
         config config-failed checks)
    (condition-case nil
        (setq config (seq-find (lambda (c) (equal profile (symbol-name (map-elt c :identifier))))
                               (mx-machina-backend-configs)))
      (error (setq config-failed t)))
    (cl-labels ((row (label severity detail) (push (list label severity detail) checks))
                (library (name)
                  (row (format "Dependency: %s" name)
                       (if (or (featurep name) (locate-library (symbol-name name))) 'ok 'blocked)
                       (if (or (featurep name) (locate-library (symbol-name name)))
                           "Available locally (not a compatibility or authentication check)"
                         "Not available; install this dependency before launching"))))
      (let* ((kind (or (map-elt config :interface)
                       (and (buffer-live-p buffer) (buffer-local-value 'mx-machina--backend-kind buffer))))
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
          (row "Hook helper" (if (file-readable-p mx-machina-claude--hook-script) 'ok 'blocked)
               (if (file-readable-p mx-machina-claude--hook-script) "Available" "Missing; reinstall the package's scripts directory")))
        (row "Recorded worktree" 'info directory)
        (row "Recorded branch" 'info (mx-machina-session-branch session))
        (cond
         ((file-remote-p directory) (row "Worktree" 'blocked "Remote worktrees are unsupported"))
         ((not (file-directory-p directory)) (row "Worktree" 'blocked "Directory missing; W associates a relocated checkout, or restore its recorded location"))
         ((not (executable-find "git")) (row "Git" 'blocked "Git is missing; actual worktree and branch could not be checked"))
         (t
          (condition-case nil
              (pcase-let ((`(,actual ,branch) (mx-machina--worktree directory)))
                (row "Actual worktree" (if (equal actual directory) 'ok 'blocked) actual)
                (row "Actual branch" (if (equal branch (mx-machina-session-branch session)) 'ok 'blocked) branch)
                (unless (equal (list actual branch) (list directory (mx-machina-session-branch session)))
                  (row "Worktree mismatch" 'blocked "Recorded and actual checkout differ; W reviews the association, or restore the recorded checkout")))
            (error (row "Worktree" 'blocked "Directory exists, but Git could not inspect a valid checkout")))))
        (row "Saved process state" 'info (mx-machina-session-status session))
        (row "Run" 'info (or (mx-machina-session-run session) "Not launched"))
        (row "Activity" 'info (mx-machina-session-activity session))
        (row "Process now" (if live 'ok 'info)
             (cond (live (format "Running (PID %s)" (process-id process)))
                   (process (format "Exited/not live (%s, exit status %s)" (process-status process) (process-exit-status process)))
                   ((equal (mx-machina-session-status session) "exited") "Exited; open the agent explicitly to resume")
                   (t "No tracked live process in this Emacs")))
        (when (and (not live) (member (mx-machina-session-status session) '("live" "starting")))
          (row "Observation" 'warning "Saved live state has no live process here; diagnostics do not reconcile it"))
        (when (mx-machina-archived-p session)
          (row "Archive" 'blocked "Archived; restore the record before starting it"))
        (row "Conversation" (if (or (mx-machina-session-conversation session)
                                     (not (mx-machina-session-run session))) 'info 'blocked)
             (or (mx-machina-session-conversation session)
                 (if (mx-machina-session-run session)
                     "Missing after a previous launch; automatic replacement is blocked"
                   "Not created yet; first explicit start will create it")))
        (row "Latest failure" (if (mx-machina-session-error session) 'warning 'info)
             (mx-machina-diagnostics--failure (mx-machina-session-error session)))
        (if (not (memq kind '(eat vterm)))
            (row "Status bridge" 'info
                 (if (eq kind 'agent-shell) "Uses ACP events; Claude terminal hooks do not apply"
                   "Cannot determine the status interface without the saved profile"))
          (if (not (and live (buffer-live-p buffer)))
              (row "Status bridge" 'info "Inactive while the terminal process is stopped")
            (with-current-buffer buffer
              (let* ((ready (mx-machina-transport-ready transport))
                     (elapsed (and mx-machina-claude--started-at
                                   (max 0 (- (float-time) mx-machina-claude--started-at))))
                     (polling (and mx-machina-claude--timer (memq mx-machina-claude--timer timer-list)))
                     (file mx-machina-claude--event-file)
                     (readable (and file (file-readable-p file))))
                (row "SessionStart" (cond (ready 'ok) ((and elapsed (> elapsed 20)) 'blocked) (t 'warning))
                     (if ready "Confirmed for this run"
                       (format "Not received%s; inspect terminal login/trust prompts and disabled hooks"
                               (if elapsed (format " after %.0fs" elapsed) ""))))
                (row "Event poller" (if polling 'ok 'warning)
                     (if polling "Active (diagnostics did not poll it)" "Inactive; status updates will not arrive"))
                (row "Event file" (if readable 'ok 'warning)
                     (if readable (format "Readable; %d bytes consumed" mx-machina-claude--offset)
                       "Not readable or not created yet; hooks may not have written an event")))))))
      (list :session session :checks (nreverse checks)
            :guidance (mx-machina-diagnostics--guidance session config config-failed)))))

(defun mx-machina-diagnostics--text (report)
  "Format REPORT for sharing, excluding raw errors and backend payloads."
  (let ((session (plist-get report :session)))
    (concat "Agent diagnostics\n"
            (format "Name: %s\nSession: %s\nEmacs: %s\n\n"
                    (mx-machina-session-name session) (mx-machina-session-id session) emacs-version)
            (format "Folder: %s\nProject: %s\nModel: %s\nUnread: %s\nArchived: %s\n\n"
                    (if (string-empty-p (mx-machina-session-folder session)) "root"
                      (mx-machina-session-folder session))
                    (or (mx-machina-session-project session) "Not recorded")
                    (or (mx-machina-session-model session) "Not reported")
                    (if (mx-machina-unread-p session) "yes" "no")
                    (if (mx-machina-archived-p session) "yes" "no"))
            (mapconcat (lambda (row) (format "[%s] %s: %s" (upcase (symbol-name (nth 1 row))) (car row) (nth 2 row)))
                       (plist-get report :checks) "\n")
            "\n\nRecovery steps\n"
            (mapconcat (lambda (step) (concat "• " step)) (plist-get report :guidance) "\n\n")
            "\n\nLocal snapshot only; provider authentication and saved history were not contacted.\n"
            "Includes local paths and IDs. Excludes raw errors, command arguments, environment values and conversation text.\n")))

(defun mx-machina-diagnostics-refresh ()
  "Refresh the diagnostic snapshot without changing agent state."
  (interactive)
  (let* ((report (mx-machina-diagnostics--collect mx-machina-diagnostics--id))
         (summary (mx-machina-diagnostics--text report))
         (failure (mx-machina-session-error (plist-get report :session)))
         (position (point))
         (inhibit-read-only t))
    (erase-buffer)
    (insert summary)
    (when failure (insert "\nLocal failure detail (omitted by w / copy summary):\n" failure "\n"))
    (goto-char (point-min))
    (while (re-search-forward "^\\[\\(OK\\|BLOCKED\\|WARNING\\)\\]" nil t)
      (add-face-text-property (match-beginning 0) (match-end 0)
                             (pcase (match-string 1) ("OK" 'success) ("BLOCKED" 'error) (_ 'warning))))
    (setq mx-machina-diagnostics--summary summary)
    (goto-char (min position (point-max)))))

(defun mx-machina-diagnostics-copy ()
  "Copy the displayed diagnostic summary, excluding the local raw error detail."
  (interactive)
  (unless mx-machina-diagnostics--summary (user-error "No diagnostic snapshot to copy"))
  (kill-new mx-machina-diagnostics--summary)
  (message "Copied diagnostics (includes paths and IDs; excludes raw error details and backend payloads)"))

(defun mx-machina-diagnostics-return ()
  "Return to the buffer shown before these diagnostics."
  (interactive)
  (if (buffer-live-p mx-machina-diagnostics--source)
      (switch-to-buffer mx-machina-diagnostics--source)
    (quit-window)))

(defvar mx-machina-diagnostics-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'mx-machina-diagnostics-refresh)
    (define-key map (kbd "w") #'mx-machina-diagnostics-copy)
    (define-key map (kbd "R") #'mx-machina-retry)
    (define-key map (kbd "W") #'mx-machina-rebind-worktree)
    (define-key map (kbd "q") #'mx-machina-diagnostics-return)
    (define-key map (kbd "?") #'mx-machina-actions)
    map))
(define-derived-mode mx-machina-diagnostics-mode special-mode "Machina Diagnostics"
  "A read-only local snapshot of agent readiness and runtime health."
  (setq-local truncate-lines nil header-line-format " Diagnostics · g refresh · w copy · W worktree · R retry · q return")
  (visual-line-mode 1))

;;;###autoload
(defun mx-machina-diagnostics (id)
  "Inspect agent ID without launching, repairing or acknowledging output."
  (interactive (list (mx-machina-diagnostics--read-id)))
  (let ((buffer (get-buffer-create (format "*Agent diagnostics %s*" (substring id 0 8)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'mx-machina-diagnostics-mode) (mx-machina-diagnostics-mode))
      (setq mx-machina-diagnostics--id id)
      (mx-machina-diagnostics-refresh))
    (mx-machina--select-main-window)
    (unless (eq (current-buffer) buffer)
      (let ((source (current-buffer)))
        (switch-to-buffer buffer)
        (setq mx-machina-diagnostics--source source)))
    buffer))

(provide 'mx-machina-diagnostics)
;;; mx-machina-diagnostics.el ends here
