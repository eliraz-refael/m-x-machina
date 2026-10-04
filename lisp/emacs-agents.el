;;; emacs-agents.el --- Persistent agent sessions and worktrees -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes
;;; Commentary:
;; M-x emacs-agents opens the dashboard.  Create a session in an existing Git
;; worktree, launch it, and resume its exact backend conversation after restart.
;;; Code:
(require 'emacs-agents-store)
(require 'emacs-agents-backend)
(require 'tabulated-list)

(declare-function magit-status "magit-status")
(declare-function eshell-mode "esh-mode")
(defvar emacs-agents--running (make-hash-table :test #'equal))
(defvar emacs-agents--timer nil)
(defvar emacs-agents--stopping nil)
(defvar-local emacs-agents--managed-id nil)
(defvar emacs-agents--ui-folders)
(defvar emacs-agents--conversation-buffers)
(defvar emacs-agents--identity)

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

(defun emacs-agents--project-name (directory)
  "Return DIRECTORY's shared Git project name, also for linked worktrees."
  (file-name-nondirectory
   (directory-file-name
    (file-name-directory
     (directory-file-name (expand-file-name (emacs-agents--git directory "rev-parse" "--git-common-dir") directory))))))

(defun emacs-agents--validate-name-profile (name profile)
  "Validate NAME and PROFILE, returning the trimmed name."
  (setq name (string-trim name))
  (when (or (string-empty-p name) (string-match-p "[[:cntrl:]]" name))
    (user-error "Use a nonempty, single-line agent name"))
  (unless (and (stringp profile) (not (string-empty-p profile)))
    (user-error "A session needs an agent profile"))
  name)

(defun emacs-agents-create (name directory profile &optional folder)
  "Persist NAME in existing Git worktree DIRECTORY using PROFILE.
Return its stable ID.  This does not start an agent or change the worktree."
  (setq name (emacs-agents--validate-name-profile name profile))
  (pcase-let ((`(,root ,branch) (emacs-agents--worktree directory)))
    (let ((id (emacs-agents--id)))
      (emacs-agents--exec
       "INSERT INTO sessions(id,name,profile,directory,branch,folder,project) VALUES(?,?,?,?,?,?,?)"
       id name profile root branch (emacs-agents-folder-create (or folder ""))
       (emacs-agents--project-name root))
      (emacs-agents-refresh)
      id)))

(defun emacs-agents-create-worktree (name directory profile branch destination &optional folder)
  "Create a worktree and save agent NAME using PROFILE and logical FOLDER.
Start new BRANCH at DIRECTORY's current commit in new DESTINATION.
Return the saved session ID without starting its backend."
  (setq name (emacs-agents--validate-name-profile name profile))
  (let* ((root (car (emacs-agents--worktree directory)))
         (commit (emacs-agents--git root "rev-parse" "HEAD"))
         (destination (directory-file-name (expand-file-name destination root))))
    (when (file-remote-p destination)
      (user-error "Only local worktrees are supported"))
    (when (or (file-exists-p destination) (file-symlink-p destination))
      (user-error "Choose a new worktree directory: %s" destination))
    (unless (equal branch (emacs-agents--git root "check-ref-format" "--branch" branch))
      (user-error "Use an explicit new branch name"))
    ;; Open/validate the registry and folder before changing Git state.
    (emacs-agents-store-open)
    (emacs-agents-folder-create (or folder ""))
    (emacs-agents--git root "worktree" "add" "-b" branch "--" destination commit)
    (condition-case err
        (emacs-agents-create name destination profile folder)
      (error
       ;; Retain files on a persistence failure; a hook may have changed them.
       (error "Worktree created at %s (branch %s), but saving the agent failed: %s. Use this existing worktree when retrying"
              destination branch (error-message-string err))))))

(defun emacs-agents--read-new-session ()
  "Read session arguments, including an optional new worktree specification."
  (let* ((name (read-string "Session name: "))
         (directory (read-directory-name "Git repository or worktree: " default-directory nil t))
         (root (car (emacs-agents--worktree directory)))
         (worktree
          (when (y-or-n-p "Create a new worktree for this agent from the current commit? ")
            (let* ((slug (string-trim
                          (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase name)) "-+" "-+"))
                   (slug (if (string-empty-p slug) "agent" slug))
                   (branch (read-string "New branch: " (concat "agent/" slug)))
                   (suggested (concat (directory-file-name root) "-" slug))
                   (path (read-directory-name "New worktree directory: "
                                              (file-name-directory suggested) suggested nil
                                              (file-name-nondirectory suggested))))
              (list branch path))))
         (profile (emacs-agents-backend-read-profile))
         (folder (emacs-agents--read-folder)))
    ;; No Git writes until all prompts, including profile/folder, finish.
    (list name root profile folder worktree)))

(defun emacs-agents--read-id ()
  "Read a session ID, preferring the current dashboard row or managed buffer."
  (or (and (derived-mode-p 'emacs-agents-mode) (tabulated-list-get-id))
      (and (derived-mode-p 'emacs-agents-sidebar-mode 'emacs-agents-board-mode)
           (get-text-property (point) 'emacs-agents-id))
      emacs-agents--managed-id
      (let ((choices (mapcar
                      (lambda (s) (cons (format "%s%s [%s]"
                                                (let ((folder (emacs-agents-session-folder s)))
                                                  (if (string-empty-p (or folder "")) "" (concat folder "/")))
                                                (emacs-agents-session-name s)
                                                (substring (emacs-agents-session-id s) 0 8))
                                        (emacs-agents-session-id s)))
                      (emacs-agents-sessions))))
        (unless choices (user-error "No sessions; use M-x emacs-agents-new"))
        (cdr (assoc (completing-read "Session: " choices nil t) choices)))))

;;;###autoload
(defun emacs-agents-new (name directory profile &optional folder worktree)
  "Create NAME using PROFILE and FOLDER, then open the dashboard.
Use existing DIRECTORY unless WORKTREE is (BRANCH DESTINATION), in which
case create a new worktree from DIRECTORY's current commit first."
  (interactive (emacs-agents--read-new-session))
  (let ((id (if worktree
                (emacs-agents-create-worktree name directory profile
                                             (car worktree) (cadr worktree) folder)
              (emacs-agents-create name directory profile folder))))
    (emacs-agents)
    (goto-char (point-min))
    (while (and (not (eobp))
                (not (equal id (get-text-property (point) 'emacs-agents-id))))
      (forward-line 1))
    (message "Session saved.  Press RET to start it.")
    id))

(defun emacs-agents--read-folder ()
  "Read a logical folder, offering the current entry as a default."
  (completing-read "Folder (Work/Project; empty = root): " (emacs-agents-folders)
                   nil nil (get-text-property (point) 'emacs-agents-folder)))

(defun emacs-agents-new-folder (path)
  "Create logical folder PATH, including its ancestors."
  (interactive (list (emacs-agents--read-folder)))
  (emacs-agents-folder-create path)
  (emacs-agents-refresh))

(defun emacs-agents-move (id path)
  "Move session ID into logical folder PATH without moving any files."
  (interactive (list (emacs-agents--read-id) (emacs-agents--read-folder)))
  (emacs-agents-session id)
  (emacs-agents--exec "UPDATE sessions SET folder=? WHERE id=?"
                      (emacs-agents-folder-create path) id)
  (emacs-agents-refresh))

(defun emacs-agents-rename (id name)
  "Rename session ID to NAME without changing its backend identity."
  (interactive (let ((id (emacs-agents--read-id)))
                 (list id (read-string "Agent name: " (emacs-agents-session-name (emacs-agents-session id))))))
  (setq name (string-trim name))
  (when (or (string-empty-p name) (string-match-p "[[:cntrl:]]" name))
    (user-error "Use a nonempty, single-line agent name"))
  (emacs-agents--exec "UPDATE sessions SET name=? WHERE id=?" name id)
  (emacs-agents-refresh))

(defun emacs-agents-mark-read (id)
  "Acknowledge unseen output for session ID."
  (interactive (list (emacs-agents--read-id)))
  (emacs-agents--reset-read-dwell id)
  (emacs-agents--exec "UPDATE sessions SET unread=0 WHERE id=?" id)
  (emacs-agents-refresh))

(defun emacs-agents--retire-for-removal (id stop-running)
  "Stop ID when explicitly authorized by STOP-RUNNING, otherwise reject it."
  (when-let* ((entry (gethash id emacs-agents--running)))
    (unless stop-running (user-error "Stop this agent first, or explicitly choose stop and archive/delete"))
    (let ((process (emacs-agents-backend-process (cdr entry))))
      (emacs-agents-stop id)
      ;; A backend may request graceful shutdown asynchronously.  Do not hide
      ;; or remove a record while its process is still alive.
      (when (and process (process-live-p process)) (delete-process process))))
  (emacs-agents--reset-read-dwell id))

(defun emacs-agents-archive (id &optional stop-running)
  "Archive ID, preserving its identity, history and worktree.
Refuse a running agent unless STOP-RUNNING explicitly authorizes stopping it."
  (interactive
   (let* ((id (emacs-agents--read-id))
          (running (gethash id emacs-agents--running)))
     (when (and running
                (not (y-or-n-p (format "Stop and archive %s? " (emacs-agents-session-name (emacs-agents-session id))))))
       (user-error "Archive cancelled"))
     (list id running)))
  (let ((session (emacs-agents-session id)))
    (emacs-agents--retire-for-removal id stop-running)
    (emacs-agents--exec "UPDATE sessions SET archived=1 WHERE id=?" id)
    (dolist (buffer emacs-agents--conversation-buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (equal id emacs-agents--managed-id)
            (setq emacs-agents--identity (format " [ARCHIVED] %s · Restore from A in the sidebar"
                                                 (emacs-agents-session-name session)))))))
    (emacs-agents-refresh)
    (message "Archived %s; A opens archived agents" (emacs-agents-session-name session))))

(defun emacs-agents-restore (id)
  "Return archived ID to the active list without starting its process."
  (interactive (list (if (derived-mode-p 'emacs-agents-archive-mode)
                         (or (tabulated-list-get-id) (user-error "No archived agent on this row"))
                       (let ((choices (mapcar (lambda (s) (cons (format "%s/%s [%s]"
                                                                          (emacs-agents-session-folder s)
                                                                          (emacs-agents-session-name s)
                                                                          (substring (emacs-agents-session-id s) 0 8))
                                                                    (emacs-agents-session-id s)))
                                              (emacs-agents-sessions 'archived))))
                         (unless choices (user-error "No archived agents"))
                         (cdr (assoc (completing-read "Restore agent: " choices nil t) choices))))))
  (emacs-agents-session id)
  (emacs-agents--exec "UPDATE sessions SET archived=0 WHERE id=?" id)
  (emacs-agents-refresh)
  (message "Agent restored; open it from the sidebar to resume"))

(defun emacs-agents-delete (id &optional stop-running)
  "Delete ID's registry record and run records; retain all worktree/history files.
Refuse a running agent unless STOP-RUNNING explicitly authorizes stopping it."
  (interactive
   (let* ((id (emacs-agents--read-id))
          (running (gethash id emacs-agents--running))
          (name (emacs-agents-session-name (emacs-agents-session id))))
     (unless (yes-or-no-p (format "%sDelete agent record %s? Conversation files and worktree will remain. "
                                  (if running "Stop its process and " "") name))
       (user-error "Delete cancelled"))
     (list id running)))
  (emacs-agents-session id)
  (emacs-agents--retire-for-removal id stop-running)
  (with-sqlite-transaction emacs-agents--db
    (emacs-agents--exec "DELETE FROM runs WHERE session=?" id)
    (emacs-agents--exec "DELETE FROM sessions WHERE id=?" id))
  ;; Keep readable buffers and shell drafts, but remove links to the deleted ID.
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (equal id emacs-agents--managed-id)
        (when (bound-and-true-p emacs-agents-conversation-mode) (emacs-agents-conversation-mode -1))
        (setq emacs-agents--managed-id nil)
        (setq-local header-line-format " Agent record deleted · Conversation text retained"))
      (when (and (boundp 'emacs-agents--shell-id) (equal id emacs-agents--shell-id))
        (setq emacs-agents--shell-id nil)
        (setq-local header-line-format " Agent record deleted · Eshell retained"))))
  (emacs-agents-refresh)
  (message "Agent record deleted; conversation files and worktree retained"))

(defun emacs-agents--backend-notice (transport kind data)
  "Apply a normalized KIND and DATA from the current TRANSPORT only."
  (maphash
   (lambda (id entry)
     (when (eq transport (cdr entry))
       (let ((session (emacs-agents-session id)))
         (when (and (equal (car entry) (emacs-agents-session-run session))
                    (equal (emacs-agents-session-status session) "live"))
           (pcase kind
             ('message
              (emacs-agents--reset-read-dwell id)
              (unless (emacs-agents-unread-p session)
                (emacs-agents--exec "UPDATE sessions SET unread=1 WHERE id=?" id)
                (emacs-agents-refresh)))
             ('metadata
              (let* ((reported (plist-get data :model))
                     (model (if (and (stringp reported) (not (string-empty-p reported)))
                                reported (emacs-agents-session-model session)))
                     (project (or (emacs-agents-session-project session)
                                 (ignore-errors (emacs-agents--project-name (emacs-agents-session-directory session))))))
                (unless (and (equal model (emacs-agents-session-model session))
                             (equal project (emacs-agents-session-project session)))
                  (emacs-agents--exec "UPDATE sessions SET model=?,project=? WHERE id=?"
                                      model project id)
                  (emacs-agents-refresh)))))))))
   emacs-agents--running))

(add-hook 'emacs-agents-backend-event-hook #'emacs-agents--backend-notice)

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
          (when (called-interactively-p 'interactive) (emacs-agents--show-conversation buffer))
          buffer)
      (let* ((session (emacs-agents-session id))
             (directory (emacs-agents-session-directory session))
             (profile (emacs-agents-session-profile session))
             (conversation (emacs-agents-session-conversation session))
             (actual (progn
                       (when (emacs-agents-archived-p session)
                         (user-error "Restore this archived agent before starting it"))
                       (emacs-agents--worktree directory))))
        (unless (equal actual (list directory (emacs-agents-session-branch session)))
          (user-error "Worktree or branch changed; use W to review its association, or restore the recorded checkout"))
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
                  (emacs-agents-conversation-mode 1)
                  (add-hook 'kill-buffer-query-functions #'emacs-agents--protect-buffer nil t))
                (unless emacs-agents--timer
                  (setq emacs-agents--timer (run-at-time 1 1 #'emacs-agents--reconcile)))
                (add-hook 'kill-emacs-hook #'emacs-agents-shutdown)
                (emacs-agents-refresh)
                (when (called-interactively-p 'interactive) (emacs-agents--show-conversation buffer))
                buffer)
            (error
             (emacs-agents--observe id run "failed" "unknown" nil (error-message-string err))
             (emacs-agents-refresh)
             (signal (car err) (cdr err)))))))))

(defun emacs-agents-open (id)
  "Open session ID, starting or resuming it when stopped."
  (interactive (list (emacs-agents--read-id)))
  (emacs-agents--show-conversation (emacs-agents-start id)))

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
    (emacs-agents--stop-ui-timer)
    (emacs-agents--stop-sidebar-observers)
    (emacs-agents-store-close)))

(defun emacs-agents-files (id)
  "Open Dired at session ID's worktree."
  (interactive (list (emacs-agents--read-id)))
  (emacs-agents--select-main-window)
  (dired (emacs-agents-session-directory (emacs-agents-session id))))

(defvar-local emacs-agents--shell-id nil)

(defun emacs-agents-eshell (id)
  "Open or revisit a separate eshell associated with agent ID's worktree."
  (interactive (list (emacs-agents--read-id)))
  (require 'eshell)
  (let* ((session (emacs-agents-session id))
         (directory (emacs-agents-session-directory session))
         (buffer (seq-find (lambda (entry) (equal id (buffer-local-value 'emacs-agents--shell-id entry)))
                           (buffer-list))))
    (unless (file-directory-p directory) (user-error "Worktree is missing: %s" directory))
    (unless buffer
      (setq buffer (generate-new-buffer (format "*Agent shell %s*" (emacs-agents-session-name session))))
      (with-current-buffer buffer
        (setq default-directory directory)
        (eshell-mode)
        (setq-local emacs-agents--shell-id id
                    header-line-format (format " %s · Eshell · %s" (emacs-agents-session-name session)
                                               (abbreviate-file-name directory)))))
    (emacs-agents--select-main-window)
    (switch-to-buffer buffer)
    buffer))

(defun emacs-agents-magit (id)
  "Open Magit at session ID's worktree."
  (interactive (list (emacs-agents--read-id)))
  (unless (require 'magit nil t) (user-error "Install Magit to inspect changes"))
  (emacs-agents--select-main-window)
  (magit-status (emacs-agents-session-directory (emacs-agents-session id))))

(autoload 'emacs-agents-diagnostics "emacs-agents-diagnostics" nil t)
(autoload 'emacs-agents-rebind-worktree "emacs-agents-recovery" nil t)
(autoload 'emacs-agents-retry "emacs-agents-recovery" nil t)
(autoload 'emacs-agents-board "emacs-agents-board" nil t)
(declare-function emacs-agents-board--refresh "emacs-agents-board")

(defun emacs-agents-details (&optional id)
  "Display local diagnostics for ID, or choose an agent interactively."
  (interactive)
  (if id (emacs-agents-diagnostics id)
    (call-interactively #'emacs-agents-diagnostics)))

(defun emacs-agents-refresh ()
  "Refresh agent views and cached counts without changing keyboard focus."
  (interactive)
  (let ((sessions (emacs-agents-sessions)))
    (setq emacs-agents--ui-folders (emacs-agents-folders))
    (emacs-agents--refresh-ui sessions)
    (when (fboundp 'emacs-agents-board--refresh) (emacs-agents-board--refresh))
    (dolist (name '("*Emacs Agents*" "*Archived Agents*"))
     (when-let* ((buffer (get-buffer name)))
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
               (if (derived-mode-p 'emacs-agents-archive-mode)
                   (emacs-agents-sessions 'archived) sessions)))
        (tabulated-list-print t))))))

(defvar emacs-agents-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "n") #'emacs-agents-new)
    (define-key map (kbd "RET") #'emacs-agents-open)
    (define-key map (kbd "r") #'emacs-agents-open)
    (define-key map (kbd "x") #'emacs-agents-stop)
    (define-key map (kbd "a") #'emacs-agents-archive)
    (define-key map (kbd "A") #'emacs-agents-archived)
    (define-key map (kbd "d") #'emacs-agents-delete)
    (define-key map (kbd "g") #'emacs-agents-refresh)
    (define-key map (kbd "f") #'emacs-agents-files)
    (define-key map (kbd "m") #'emacs-agents-magit)
    (define-key map (kbd "i") #'emacs-agents-details)
    (define-key map (kbd "B") #'emacs-agents-board)
    (define-key map (kbd "W") #'emacs-agents-rebind-worktree)
    (define-key map (kbd "e") #'emacs-agents-eshell)
    (define-key map (kbd "z") #'emacs-agents-focus)
    (define-key map (kbd "s") #'emacs-agents)
    map))

(define-derived-mode emacs-agents-mode tabulated-list-mode "Agents"
  "Dashboard for persistent coding-agent sessions."
  (setq tabulated-list-format [("Session" 20 t) ("Process" 10 t) ("Activity" 10 t)
                               ("Profile" 22 t) ("Branch" 20 t) ("Identity" 9 t)
                               ("Worktree" 0 t)]
        tabulated-list-padding 1)
  (setq-local header-line-format " n new   RET open   x stop   a archive   A archived   d delete   e eshell   g refresh")
  (add-hook 'tabulated-list-revert-hook #'emacs-agents-refresh nil t)
  (tabulated-list-init-header))

(defvar emacs-agents-archive-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map emacs-agents-mode-map)
    (define-key map (kbd "RET") #'emacs-agents-restore)
    (define-key map (kbd "r") #'emacs-agents-restore)
    (define-key map (kbd "A") #'emacs-agents-dashboard)
    map))

(define-derived-mode emacs-agents-archive-mode emacs-agents-mode "Archived Agents"
  "Archived records; RET restores without launching and d deletes only the record."
  (setq-local header-line-format " Archived agents · RET/r restore   d delete record   A active agents   q close"))

(defun emacs-agents-archived ()
  "Show archived agents without launching or restoring any agent."
  (interactive)
  (emacs-agents)
  (emacs-agents--select-main-window)
  (switch-to-buffer (get-buffer-create "*Archived Agents*"))
  (unless (derived-mode-p 'emacs-agents-archive-mode) (emacs-agents-archive-mode))
  (emacs-agents-refresh))

;;;###autoload
(defun emacs-agents-dashboard ()
  "Open the expanded session dashboard without launching agents."
  (interactive)
  (emacs-agents)
  (emacs-agents--select-main-window)
  (with-current-buffer (get-buffer-create "*Emacs Agents*")
    (emacs-agents-mode)
    (emacs-agents-refresh)
    (pop-to-buffer (current-buffer))))

(require 'emacs-agents-ui)

(provide 'emacs-agents)
;;; emacs-agents.el ends here
