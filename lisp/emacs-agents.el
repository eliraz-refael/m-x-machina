;;; emacs-agents.el --- Persistent agent sessions and worktrees -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.75.2"))
;; Keywords: tools, processes
;;; Commentary:
;; M-x emacs-agents opens the dashboard.  Create a session in an existing Git
;; worktree, launch it, and resume its exact backend conversation after restart.
;;; Code:
(require 'emacs-agents-store)
(require 'emacs-agents-agent-shell)
(require 'tabulated-list)

(declare-function magit-status "magit-status")
(defvar emacs-agents--running (make-hash-table :test #'equal))
(defvar emacs-agents--timer nil)
(defvar emacs-agents--stopping nil)
(defvar-local emacs-agents--managed-id nil)

(defun emacs-agents--git (directory &rest args)
  "Run Git ARGS in DIRECTORY, returning trimmed output or an error."
  (let ((default-directory directory))
    (with-temp-buffer
      (unless (zerop (apply #'process-file "git" nil '(t t) nil args))
        (user-error "Git: %s" (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun emacs-agents--worktree (directory)
  "Validate DIRECTORY and return its canonical worktree root and branch."
  (when (file-remote-p directory) (user-error "Only local worktrees are supported"))
  (unless (file-directory-p directory) (user-error "Worktree is missing: %s" directory))
  (let* ((root (file-name-as-directory
                (file-truename (emacs-agents--git directory "rev-parse" "--show-toplevel"))))
         (branch (emacs-agents--git root "rev-parse" "--abbrev-ref" "HEAD")))
    (list root (if (equal branch "HEAD")
                   (concat "detached:" (emacs-agents--git root "rev-parse" "HEAD"))
                 branch))))

(defun emacs-agents-create (name directory profile)
  "Persist NAME in existing Git worktree DIRECTORY using PROFILE.
Return its stable ID.  This does not start an agent or change the worktree."
  (setq name (string-trim name))
  (when (string-empty-p name) (user-error "A session needs a name"))
  (unless (and (stringp profile) (not (string-empty-p profile)))
    (user-error "A session needs an agent profile"))
  (pcase-let ((`(,root ,branch) (emacs-agents--worktree directory)))
    (let ((id (emacs-agents--id)))
      (emacs-agents--exec
       "INSERT INTO sessions(id,name,profile,directory,branch) VALUES(?,?,?,?,?)"
       id name profile root branch)
      (emacs-agents-refresh)
      id)))

(defun emacs-agents--read-id ()
  "Read a session ID, preferring the current dashboard row or managed buffer."
  (or (and (derived-mode-p 'emacs-agents-mode) (tabulated-list-get-id))
      emacs-agents--managed-id
      (let ((choices (mapcar
                      (lambda (s) (cons (format "%s [%s]" (emacs-agents-session-name s)
                                                (substring (emacs-agents-session-id s) 0 8))
                                        (emacs-agents-session-id s)))
                      (emacs-agents-sessions))))
        (unless choices (user-error "No sessions; use M-x emacs-agents-new"))
        (cdr (assoc (completing-read "Session: " choices nil t) choices)))))

;;;###autoload
(defun emacs-agents-new (name directory profile)
  "Create NAME in DIRECTORY using PROFILE, then open the dashboard."
  (interactive
   (list (read-string "Session name: ")
         (read-directory-name "Existing Git worktree: " default-directory nil t)
         (completing-read
          "Agent profile: "
          (mapcar (lambda (config) (symbol-name (map-elt config :identifier)))
                  (emacs-agents-backend-configs)) nil t)))
  (let ((id (emacs-agents-create name directory profile)))
    (emacs-agents)
    (goto-char (point-min))
    (while (and (not (eobp)) (not (equal id (tabulated-list-get-id)))) (forward-line 1))
    (message "Session saved.  Press RET to start it.")
    id))

(defun emacs-agents--protect-buffer ()
  "Keep a managed transport alive when its buffer is accidentally killed."
  (if (or emacs-agents--stopping (not emacs-agents--managed-id)
          (not (gethash emacs-agents--managed-id emacs-agents--running)))
      t
    (message "Use emacs-agents-stop to stop this session; bury the buffer to hide it")
    nil))

(defun emacs-agents-start (id)
  "Start or resume session ID, returning its interactive buffer.
Never replay input or create a replacement for a saved conversation."
  (interactive (list (emacs-agents--read-id)))
  (let ((existing (gethash id emacs-agents--running)))
    (if existing
        (let ((buffer (emacs-agents-transport-buffer (cdr existing))))
          (when (called-interactively-p 'interactive) (pop-to-buffer buffer))
          buffer)
      (let* ((session (emacs-agents-session id))
             (directory (emacs-agents-session-directory session))
             (profile (emacs-agents-session-profile session))
             (conversation (emacs-agents-session-conversation session))
             (actual (emacs-agents--worktree directory)))
        (unless (equal actual (list directory (emacs-agents-session-branch session)))
          (user-error "Worktree or branch changed; restore its recorded location and branch first"))
        (when (and (emacs-agents-session-run session) (not conversation))
          (user-error "Previous launch captured no conversation ID; inspect its buffer, or create a new session explicitly"))
        ;; Validate the profile before allocating a run.
        (unless (seq-find (lambda (c) (equal profile (symbol-name (map-elt c :identifier))))
                          (emacs-agents-backend-configs))
          (user-error "Restore the saved profile: %s" profile))
        (let ((run (emacs-agents--begin-run id)))
          (condition-case err
              (let* ((transport
                      (emacs-agents-backend-start
                       profile directory conversation
                       (lambda (status activity &optional sid message)
                         (when (emacs-agents--observe id run status activity sid message)
                           (emacs-agents-refresh)))))
                     (buffer (emacs-agents-transport-buffer transport)))
                (puthash id (cons run transport) emacs-agents--running)
                (with-current-buffer buffer
                  (setq-local emacs-agents--managed-id id)
                  (add-hook 'kill-buffer-query-functions #'emacs-agents--protect-buffer nil t))
                (unless emacs-agents--timer
                  (setq emacs-agents--timer (run-at-time 1 1 #'emacs-agents--reconcile)))
                (add-hook 'kill-emacs-hook #'emacs-agents-shutdown)
                (emacs-agents-refresh)
                (when (called-interactively-p 'interactive) (pop-to-buffer buffer))
                buffer)
            (error
             (emacs-agents--observe id run "failed" "unknown" nil (error-message-string err))
             (emacs-agents-refresh)
             (signal (car err) (cdr err)))))))))

(defun emacs-agents-open (id)
  "Open session ID, starting or resuming it when stopped."
  (interactive (list (emacs-agents--read-id)))
  (pop-to-buffer (emacs-agents-start id)))

(defun emacs-agents-stop (id)
  "Stop the managed process for ID and preserve its conversation and buffer."
  (interactive (list (emacs-agents--read-id)))
  (when-let* ((entry (gethash id emacs-agents--running)))
    (emacs-agents-backend-stop (cdr entry))
    (emacs-agents--observe id (car entry) "stopped" "unknown")
    (remhash id emacs-agents--running))
  (emacs-agents-refresh))

(defun emacs-agents--reconcile ()
  "Reconcile managed processes; retain failed records and retire ended runs."
  (let (ended)
    (maphash
     (lambda (id entry)
       (let ((transport (cdr entry)))
         (when (or (emacs-agents-transport-stopping transport)
                   (and (emacs-agents-transport-ready transport)
                        (not (emacs-agents-backend-process transport)))
                   (and (emacs-agents-backend-process transport)
                        (not (process-live-p (emacs-agents-backend-process transport))))
                   (not (buffer-live-p (emacs-agents-transport-buffer transport))))
           (emacs-agents--observe id (car entry) "exited" "unknown")
           (push id ended))))
     emacs-agents--running)
    (dolist (id ended) (remhash id emacs-agents--running))
    (when ended (emacs-agents-refresh))
    (when (and emacs-agents--timer (zerop (hash-table-count emacs-agents--running)))
      (cancel-timer emacs-agents--timer)
      (setq emacs-agents--timer nil))))

(defun emacs-agents-shutdown ()
  "Stop managed transports and close the registry."
  (interactive)
  (let ((emacs-agents--stopping t))
    (dolist (id (hash-table-keys emacs-agents--running)) (emacs-agents-stop id))
    (when emacs-agents--timer (cancel-timer emacs-agents--timer))
    (setq emacs-agents--timer nil)
    (emacs-agents-store-close)))

(defun emacs-agents-files (id)
  "Open Dired at session ID's worktree."
  (interactive (list (emacs-agents--read-id)))
  (dired (emacs-agents-session-directory (emacs-agents-session id))))

(defun emacs-agents-magit (id)
  "Open Magit at session ID's worktree."
  (interactive (list (emacs-agents--read-id)))
  (unless (require 'magit nil t) (user-error "Install Magit to inspect changes"))
  (magit-status (emacs-agents-session-directory (emacs-agents-session id))))

(defun emacs-agents-details (id)
  "Display session ID's persisted identity and last diagnostic."
  (interactive (list (emacs-agents--read-id)))
  (let ((s (emacs-agents-session id)))
    (with-help-window "*Agent session*"
      (princ (format "%s\n\nSession: %s\nProfile: %s\nWorktree: %s\nBranch: %s\nConversation: %s\nRun: %s\nProcess: %s\nActivity: %s\n\n%s\n"
                     (emacs-agents-session-name s) id (emacs-agents-session-profile s)
                     (emacs-agents-session-directory s) (emacs-agents-session-branch s)
                     (or (emacs-agents-session-conversation s) "Not captured yet")
                     (or (emacs-agents-session-run s) "Not launched")
                     (emacs-agents-session-status s) (emacs-agents-session-activity s)
                     (or (emacs-agents-session-error s) ""))))))

(defun emacs-agents-refresh ()
  "Refresh an existing dashboard while preserving the selected session."
  (interactive)
  (when-let* ((buffer (get-buffer "*Emacs Agents*")))
    (with-current-buffer buffer
      (setq tabulated-list-entries
            (mapcar
             (lambda (s)
               (list (emacs-agents-session-id s)
                     (vector (emacs-agents-session-name s) (emacs-agents-session-status s)
                             (emacs-agents-session-activity s) (emacs-agents-session-profile s)
                             (emacs-agents-session-branch s)
                             (if (emacs-agents-session-conversation s) "saved" "pending")
                             (abbreviate-file-name (emacs-agents-session-directory s)))))
             (emacs-agents-sessions)))
      (tabulated-list-print t))))

(defvar emacs-agents-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "n") #'emacs-agents-new)
    (define-key map (kbd "RET") #'emacs-agents-open)
    (define-key map (kbd "r") #'emacs-agents-open)
    (define-key map (kbd "x") #'emacs-agents-stop)
    (define-key map (kbd "g") #'emacs-agents-refresh)
    (define-key map (kbd "f") #'emacs-agents-files)
    (define-key map (kbd "m") #'emacs-agents-magit)
    (define-key map (kbd "i") #'emacs-agents-details)
    map))

(define-derived-mode emacs-agents-mode tabulated-list-mode "Agents"
  "Dashboard for persistent coding-agent sessions."
  (setq tabulated-list-format [("Session" 20 t) ("Process" 10 t) ("Activity" 10 t)
                               ("Profile" 22 t) ("Branch" 20 t) ("Identity" 9 t)
                               ("Worktree" 0 t)]
        tabulated-list-padding 1)
  (setq-local header-line-format " n new   RET open/resume   x stop   f files   m Magit   i details   g refresh")
  (add-hook 'tabulated-list-revert-hook #'emacs-agents-refresh nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun emacs-agents ()
  "Open the session dashboard without launching agents."
  (interactive)
  (emacs-agents-store-open)
  (add-hook 'kill-emacs-hook #'emacs-agents-shutdown)
  (with-current-buffer (get-buffer-create "*Emacs Agents*")
    (emacs-agents-mode)
    (emacs-agents-refresh)
    (pop-to-buffer (current-buffer))))

(provide 'emacs-agents)
;;; emacs-agents.el ends here
