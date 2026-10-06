;;; mx-machina.el --- Persistent agent sessions and worktrees -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eliraz Kedmi
;; Author: Eliraz Kedmi <eliraz.kedmi@gmail.com>
;; Assisted-by: Codex:gpt-6
;; Maintainer: Eliraz Kedmi <eliraz.kedmi@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later
;; URL: https://github.com/eliraz-refael/m-x-machina
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes
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
;; M-x Machina: your coding-agent workspace.  Create a session in an existing Git
;; worktree, launch it, and resume its exact backend conversation after restart.
;;; Code:
(require 'mx-machina-store)
(require 'mx-machina-backend)
(require 'tabulated-list)

(autoload 'mx-machina-messaging-ready "mx-machina-messaging" nil t)
(autoload 'mx-machina-messaging-mode "mx-machina-messaging" nil t)
(declare-function mx-machina-messaging-environment "mx-machina-messaging")

(declare-function magit-status "magit-status")
(declare-function eshell-mode "esh-mode")
(defvar mx-machina--running (make-hash-table :test #'equal))
(defvar mx-machina--timer nil)
(defvar mx-machina--stopping nil)
(defvar-local mx-machina--managed-id nil)
(defvar mx-machina--ui-folders)
(defvar mx-machina--conversation-buffers)
(defvar mx-machina--identity)

(defun mx-machina--git (directory &rest args)
  "Run Git ARGS in DIRECTORY, returning trimmed output or an error."
  (let ((default-directory directory))
    (with-temp-buffer
      (unless (zerop (apply #'process-file "git" nil '(t t) nil args))
        (user-error "Git: %s" (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun mx-machina--worktree (directory)
  "Validate DIRECTORY and return its canonical worktree root and branch."
  (when (file-remote-p directory) (user-error "Only local worktrees are supported"))
  (unless (file-directory-p directory) (user-error "Worktree is missing: %s" directory))
  (let* ((root (file-name-as-directory
                (file-truename (mx-machina--git directory "rev-parse" "--show-toplevel"))))
         (branch (mx-machina--git root "rev-parse" "--abbrev-ref" "HEAD")))
    (list root (if (equal branch "HEAD")
                   (concat "detached:" (mx-machina--git root "rev-parse" "HEAD"))
                 branch))))

(defun mx-machina--project-name (directory)
  "Return DIRECTORY's shared Git project name, also for linked worktrees."
  (file-name-nondirectory
   (directory-file-name
    (file-name-directory
     (directory-file-name (expand-file-name (mx-machina--git directory "rev-parse" "--git-common-dir") directory))))))

(defun mx-machina--validate-name-profile (name profile)
  "Validate NAME and PROFILE, returning the trimmed name."
  (setq name (string-trim name))
  (when (or (string-empty-p name) (string-match-p "[[:cntrl:]]" name))
    (user-error "Use a nonempty, single-line agent name"))
  (unless (and (stringp profile) (not (string-empty-p profile)))
    (user-error "A session needs an agent profile"))
  name)

(defun mx-machina-create (name directory profile &optional folder)
  "Persist NAME in existing Git worktree DIRECTORY using PROFILE and FOLDER.
Return its stable ID.  This does not start an agent or change the worktree."
  (setq name (mx-machina--validate-name-profile name profile))
  (pcase-let ((`(,root ,branch) (mx-machina--worktree directory)))
    (let ((id (mx-machina--id)))
      (mx-machina--exec
       "INSERT INTO sessions(id,name,profile,directory,branch,folder,project) VALUES(?,?,?,?,?,?,?)"
       id name profile root branch (mx-machina-folder-create (or folder ""))
       (mx-machina--project-name root))
      (mx-machina-refresh)
      id)))

(defun mx-machina-create-worktree (name directory profile branch destination &optional folder)
  "Create a worktree and save agent NAME using PROFILE and logical FOLDER.
Start new BRANCH at DIRECTORY's current commit in new DESTINATION.
Return the saved session ID without starting its backend."
  (setq name (mx-machina--validate-name-profile name profile))
  (let* ((root (car (mx-machina--worktree directory)))
         (commit (mx-machina--git root "rev-parse" "HEAD"))
         (destination (directory-file-name (expand-file-name destination root))))
    (when (file-remote-p destination)
      (user-error "Only local worktrees are supported"))
    (when (or (file-exists-p destination) (file-symlink-p destination))
      (user-error "Choose a new worktree directory: %s" destination))
    (unless (equal branch (mx-machina--git root "check-ref-format" "--branch" branch))
      (user-error "Use an explicit new branch name"))
    ;; Open/validate the registry and folder before changing Git state.
    (mx-machina-store-open)
    (mx-machina-folder-create (or folder ""))
    (mx-machina--git root "worktree" "add" "-b" branch "--" destination commit)
    (condition-case err
        (mx-machina-create name destination profile folder)
      (error
       ;; Retain files on a persistence failure; a hook may have changed them.
       (error "Worktree created at %s (branch %s), but saving the agent failed: %s. Use this existing worktree when retrying"
              destination branch (error-message-string err))))))

(defun mx-machina--read-new-session ()
  "Read session arguments, including an optional new worktree specification."
  (let* ((name (read-string "Session name: "))
         (directory (read-directory-name "Git repository or worktree: " default-directory nil t))
         (root (car (mx-machina--worktree directory)))
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
         (profile (mx-machina-backend-read-profile))
         (folder (mx-machina--read-folder)))
    ;; No Git writes until all prompts, including profile/folder, finish.
    (list name root profile folder worktree)))

(defun mx-machina--read-id ()
  "Read a session ID, preferring the current dashboard row or managed buffer."
  (or (and (derived-mode-p 'mx-machina-mode) (tabulated-list-get-id))
      (and (derived-mode-p 'mx-machina-sidebar-mode 'mx-machina-board-mode)
           (get-text-property (point) 'mx-machina-id))
      mx-machina--managed-id
      (let ((choices (mapcar
                      (lambda (s) (cons (format "%s%s [%s]"
                                                (let ((folder (mx-machina-session-folder s)))
                                                  (if (string-empty-p (or folder "")) "" (concat folder "/")))
                                                (mx-machina-session-name s)
                                                (substring (mx-machina-session-id s) 0 8))
                                        (mx-machina-session-id s)))
                      (mx-machina-sessions))))
        (unless choices (user-error "No sessions; use M-x mx-machina-new"))
        (cdr (assoc (completing-read "Session: " choices nil t) choices)))))

;;;###autoload
(defun mx-machina-new (name directory profile &optional folder worktree)
  "Create NAME using PROFILE and FOLDER, then open the dashboard.
Use existing DIRECTORY unless WORKTREE is (BRANCH DESTINATION), in which
case create a new worktree from DIRECTORY's current commit first."
  (interactive (mx-machina--read-new-session))
  (let ((id (if worktree
                (mx-machina-create-worktree name directory profile
                                             (car worktree) (cadr worktree) folder)
              (mx-machina-create name directory profile folder))))
    (mx-machina)
    (goto-char (point-min))
    (while (and (not (eobp))
                (not (equal id (get-text-property (point) 'mx-machina-id))))
      (forward-line 1))
    (message "Session saved.  Press RET to start it.")
    id))

(defun mx-machina--read-folder ()
  "Read a logical folder, offering the current entry as a default."
  (completing-read "Folder (Work/Project; empty = root): " (mx-machina-folders)
                   nil nil (get-text-property (point) 'mx-machina-folder)))

;;;###autoload
(defun mx-machina-new-folder (path)
  "Create logical folder PATH, including its ancestors."
  (interactive (list (mx-machina--read-folder)))
  (mx-machina-folder-create path)
  (mx-machina-refresh))

;;;###autoload
(defun mx-machina-move (id path)
  "Move session ID into logical folder PATH without moving any files."
  (interactive (list (mx-machina--read-id) (mx-machina--read-folder)))
  (mx-machina-session id)
  (mx-machina--exec "UPDATE sessions SET folder=? WHERE id=?"
                      (mx-machina-folder-create path) id)
  (mx-machina-refresh))

;;;###autoload
(defun mx-machina-rename (id name)
  "Rename session ID to NAME without changing its backend identity."
  (interactive (let ((id (mx-machina--read-id)))
                 (list id (read-string "Agent name: " (mx-machina-session-name (mx-machina-session id))))))
  (setq name (string-trim name))
  (when (or (string-empty-p name) (string-match-p "[[:cntrl:]]" name))
    (user-error "Use a nonempty, single-line agent name"))
  (mx-machina--exec "UPDATE sessions SET name=? WHERE id=?" name id)
  (mx-machina-refresh))

;;;###autoload
(defun mx-machina-mark-read (id)
  "Acknowledge unseen output for session ID."
  (interactive (list (mx-machina--read-id)))
  (mx-machina--reset-read-dwell id)
  (mx-machina--exec "UPDATE sessions SET unread=0 WHERE id=?" id)
  (mx-machina-refresh))

(defun mx-machina--retire-for-removal (id stop-running)
  "Stop ID when explicitly authorized by STOP-RUNNING, otherwise reject it."
  (when-let* ((entry (gethash id mx-machina--running)))
    (unless stop-running (user-error "Stop this agent first, or explicitly choose stop and archive/delete"))
    (let ((process (mx-machina-backend-process (cdr entry))))
      (mx-machina-stop id)
      ;; A backend may request graceful shutdown asynchronously.  Do not hide
      ;; or remove a record while its process is still alive.
      (when (and process (process-live-p process)) (delete-process process))))
  (mx-machina--reset-read-dwell id))

;;;###autoload
(defun mx-machina-archive (id &optional stop-running)
  "Archive ID, preserving its identity, history and worktree.
Refuse a running agent unless STOP-RUNNING explicitly authorizes stopping it."
  (interactive
   (let* ((id (mx-machina--read-id))
          (running (gethash id mx-machina--running)))
     (when (and running
                (not (y-or-n-p (format "Stop and archive %s? " (mx-machina-session-name (mx-machina-session id))))))
       (user-error "Archive cancelled"))
     (list id running)))
  (let ((session (mx-machina-session id)))
    (mx-machina--retire-for-removal id stop-running)
    (mx-machina--exec "UPDATE sessions SET archived=1 WHERE id=?" id)
    (dolist (buffer mx-machina--conversation-buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (equal id mx-machina--managed-id)
            (setq mx-machina--identity (format " [ARCHIVED] %s · Restore from A in the sidebar"
                                                 (mx-machina-session-name session)))))))
    (mx-machina-refresh)
    (message "Archived %s; A opens archived agents" (mx-machina-session-name session))))

;;;###autoload
(defun mx-machina-restore (id)
  "Return archived ID to the active list without starting its process."
  (interactive (list (if (derived-mode-p 'mx-machina-archive-mode)
                         (or (tabulated-list-get-id) (user-error "No archived agent on this row"))
                       (let ((choices (mapcar (lambda (s) (cons (format "%s/%s [%s]"
                                                                          (mx-machina-session-folder s)
                                                                          (mx-machina-session-name s)
                                                                          (substring (mx-machina-session-id s) 0 8))
                                                                    (mx-machina-session-id s)))
                                              (mx-machina-sessions 'archived))))
                         (unless choices (user-error "No archived agents"))
                         (cdr (assoc (completing-read "Restore agent: " choices nil t) choices))))))
  (mx-machina-session id)
  (mx-machina--exec "UPDATE sessions SET archived=0 WHERE id=?" id)
  (mx-machina-refresh)
  (message "Agent restored; open it from the sidebar to resume"))

;;;###autoload
(defun mx-machina-delete (id &optional stop-running)
  "Delete ID's registry record and run records; retain all worktree/history files.
Refuse a running agent unless STOP-RUNNING explicitly authorizes stopping it."
  (interactive
   (let* ((id (mx-machina--read-id))
          (running (gethash id mx-machina--running))
          (name (mx-machina-session-name (mx-machina-session id))))
     (unless (yes-or-no-p (format "Conversation files and worktree will remain.  %sDelete agent record %s? "
                                  (if running "Stop its process and " "") name))
       (user-error "Delete cancelled"))
     (list id running)))
  (mx-machina-session id)
  (mx-machina--retire-for-removal id stop-running)
  (mx-machina--with-transaction mx-machina--db
    (mx-machina--exec "DELETE FROM runs WHERE session=?" id)
    (mx-machina--exec "DELETE FROM sessions WHERE id=?" id))
  ;; Keep readable buffers and shell drafts, but remove links to the deleted ID.
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (equal id mx-machina--managed-id)
        (when (bound-and-true-p mx-machina-conversation-mode) (mx-machina-conversation-mode -1))
        (setq mx-machina--managed-id nil)
        (setq-local header-line-format " Agent record deleted · Conversation text retained"))
      (when (and (boundp 'mx-machina--shell-id) (equal id mx-machina--shell-id))
        (setq mx-machina--shell-id nil)
        (setq-local header-line-format " Agent record deleted · Eshell retained"))))
  (mx-machina-refresh)
  (message "Agent record deleted; conversation files and worktree retained"))

(defun mx-machina--backend-notice (transport kind data)
  "Apply a normalized KIND and DATA from the current TRANSPORT only."
  (maphash
   (lambda (id entry)
     (when (eq transport (cdr entry))
       (let ((session (mx-machina-session id)))
         (when (and (equal (car entry) (mx-machina-session-run session))
                    (equal (mx-machina-session-status session) "live"))
           (pcase kind
             ('message
              (mx-machina--reset-read-dwell id)
              (unless (mx-machina-unread-p session)
                (mx-machina--exec "UPDATE sessions SET unread=1 WHERE id=?" id)
                (mx-machina-refresh)))
             ('metadata
              (let* ((reported (plist-get data :model))
                     (model (if (and (stringp reported) (not (string-empty-p reported)))
                                reported (mx-machina-session-model session)))
                     (project (or (mx-machina-session-project session)
                                 (ignore-errors (mx-machina--project-name (mx-machina-session-directory session))))))
                (unless (and (equal model (mx-machina-session-model session))
                             (equal project (mx-machina-session-project session)))
                  (mx-machina--exec "UPDATE sessions SET model=?,project=? WHERE id=?"
                                      model project id)
                  (mx-machina-refresh)))))))))
   mx-machina--running))

(add-hook 'mx-machina-backend-event-hook #'mx-machina--backend-notice)

(defun mx-machina--protect-buffer ()
  "Keep a managed transport alive when its buffer is accidentally killed."
  (if (or mx-machina--stopping (not mx-machina--managed-id)
          (not (gethash mx-machina--managed-id mx-machina--running)))
      t
    (message "Use mx-machina-stop to stop this session; bury the buffer to hide it")
    nil))

(defun mx-machina-start (id)
  "Start or resume session ID, returning its interactive buffer.
Never replay input or create a replacement for a saved conversation."
  (interactive (list (mx-machina--read-id)))
  (let ((existing (gethash id mx-machina--running)))
    (if existing
        (let ((buffer (mx-machina-transport-buffer (cdr existing))))
          (when (called-interactively-p 'interactive) (mx-machina--show-conversation buffer))
          buffer)
      (let* ((session (mx-machina-session id))
             (directory (mx-machina-session-directory session))
             (profile (mx-machina-session-profile session))
             (conversation (mx-machina-session-conversation session))
             (actual (progn
                       (when (mx-machina-archived-p session)
                         (user-error "Restore this archived agent before starting it"))
                       (mx-machina--worktree directory))))
        (unless (equal actual (list directory (mx-machina-session-branch session)))
          (user-error "Worktree or branch changed; use W to review its association, or restore the recorded checkout"))
        (when (and (mx-machina-session-run session) (not conversation))
          (user-error "Previous launch captured no conversation ID; inspect its buffer, or create a new session explicitly"))
        ;; Validate the profile before allocating a run.
        (unless (seq-find (lambda (c) (equal profile (symbol-name (map-elt c :identifier))))
                          (mx-machina-backend-configs))
          (user-error "Restore the saved profile: %s" profile))
        (let ((run (mx-machina--begin-run id)))
          (condition-case err
              (let* ((process-environment
                      (append (when (bound-and-true-p mx-machina-messaging-mode)
                                (mx-machina-messaging-environment id)) process-environment))
                     (transport
                      (mx-machina-backend-start
                       profile directory conversation
                       (lambda (status activity &optional sid message)
                         (when (mx-machina--observe id run status activity sid message)
                           (mx-machina-refresh)))))
                     (buffer (mx-machina-transport-buffer transport)))
                (puthash id (cons run transport) mx-machina--running)
                (with-current-buffer buffer
                  (setq-local mx-machina--managed-id id)
                  (mx-machina-conversation-mode 1)
                  (add-hook 'kill-buffer-query-functions #'mx-machina--protect-buffer nil t))
                (unless mx-machina--timer
                  (setq mx-machina--timer (run-at-time 1 1 #'mx-machina--reconcile)))
                (add-hook 'kill-emacs-hook #'mx-machina-shutdown)
                (mx-machina-refresh)
                (when (called-interactively-p 'interactive) (mx-machina--show-conversation buffer))
                buffer)
            (error
             (mx-machina--observe id run "failed" "unknown" nil (error-message-string err))
             (mx-machina-refresh)
             (signal (car err) (cdr err)))))))))

;;;###autoload
(defun mx-machina-open (id)
  "Open session ID, starting or resuming it when stopped."
  (interactive (list (mx-machina--read-id)))
  (mx-machina--show-conversation (mx-machina-start id)))

;;;###autoload
(defun mx-machina-stop (id)
  "Stop the managed process for ID and preserve its conversation and buffer."
  (interactive (list (mx-machina--read-id)))
  (when-let* ((entry (gethash id mx-machina--running)))
    (mx-machina-backend-stop (cdr entry))
    (mx-machina--observe id (car entry) "stopped" "unknown")
    (remhash id mx-machina--running))
  (mx-machina-refresh))

(defun mx-machina--reconcile ()
  "Reconcile managed processes; retain failed records and retire ended runs."
  (let (ended)
    (maphash
     (lambda (id entry)
       (let ((transport (cdr entry)))
         (when (or (mx-machina-transport-stopping transport)
                   (and (mx-machina-transport-ready transport)
                        (not (mx-machina-backend-process transport)))
                   (and (mx-machina-backend-process transport)
                        (not (process-live-p (mx-machina-backend-process transport))))
                   (not (buffer-live-p (mx-machina-transport-buffer transport))))
           (mx-machina--observe id (car entry) "exited" "unknown")
           (push id ended))))
     mx-machina--running)
    (dolist (id ended) (remhash id mx-machina--running))
    (when ended (mx-machina-refresh))
    (when (and mx-machina--timer (zerop (hash-table-count mx-machina--running)))
      (cancel-timer mx-machina--timer)
      (setq mx-machina--timer nil))))

(defun mx-machina-shutdown ()
  "Stop managed transports and close the registry."
  (interactive)
  (when (bound-and-true-p mx-machina-messaging-mode) (mx-machina-messaging-mode -1))
  (let ((mx-machina--stopping t))
    (dolist (id (hash-table-keys mx-machina--running)) (mx-machina-stop id))
    (when mx-machina--timer (cancel-timer mx-machina--timer))
    (setq mx-machina--timer nil)
    (mx-machina--stop-ui-timer)
    (mx-machina--stop-sidebar-observers)
    (mx-machina-store-close)))

;;;###autoload
(defun mx-machina-files (id)
  "Open Dired at session ID's worktree."
  (interactive (list (mx-machina--read-id)))
  (mx-machina--select-main-window)
  (dired (mx-machina-session-directory (mx-machina-session id))))

(defvar-local mx-machina--shell-id nil)

;;;###autoload
(defun mx-machina-eshell (id)
  "Open or revisit a separate eshell associated with agent ID's worktree."
  (interactive (list (mx-machina--read-id)))
  (require 'eshell)
  (let* ((session (mx-machina-session id))
         (directory (mx-machina-session-directory session))
         (buffer (seq-find (lambda (entry) (equal id (buffer-local-value 'mx-machina--shell-id entry)))
                           (buffer-list))))
    (unless (file-directory-p directory) (user-error "Worktree is missing: %s" directory))
    (unless buffer
      (setq buffer (generate-new-buffer (format "*Agent shell %s*" (mx-machina-session-name session))))
      (with-current-buffer buffer
        (setq default-directory directory)
        (eshell-mode)
        (setq-local mx-machina--shell-id id
                    header-line-format (format " %s · Eshell · %s" (mx-machina-session-name session)
                                               (abbreviate-file-name directory)))))
    (mx-machina--select-main-window)
    (switch-to-buffer buffer)
    buffer))

;;;###autoload
(defun mx-machina-magit (id)
  "Open Magit at session ID's worktree."
  (interactive (list (mx-machina--read-id)))
  (unless (require 'magit nil t) (user-error "Install Magit to inspect changes"))
  (mx-machina--select-main-window)
  (magit-status (mx-machina-session-directory (mx-machina-session id))))

(autoload 'mx-machina-diagnostics "mx-machina-diagnostics" nil t)
(autoload 'mx-machina-rebind-worktree "mx-machina-recovery" nil t)
(autoload 'mx-machina-retry "mx-machina-recovery" nil t)
(autoload 'mx-machina-board "mx-machina-board" nil t)
(autoload 'mx-machina-actions "mx-machina-actions" nil t)
(autoload 'mx-machina-next-attention "mx-machina-attention" nil t)
(autoload 'mx-machina-previous-attention "mx-machina-attention" nil t)
(autoload 'mx-machina-next-waiting "mx-machina-attention" nil t)
(autoload 'mx-machina-previous-waiting "mx-machina-attention" nil t)
(autoload 'mx-machina-next-unread "mx-machina-attention" nil t)
(autoload 'mx-machina-previous-unread "mx-machina-attention" nil t)
(declare-function mx-machina-board--refresh "mx-machina-board")

;;;###autoload
(defun mx-machina-details (&optional id)
  "Display local diagnostics for ID, or choose an agent interactively."
  (interactive)
  (if id (mx-machina-diagnostics id)
    (call-interactively #'mx-machina-diagnostics)))

;;;###autoload
(defun mx-machina-refresh ()
  "Refresh agent views and cached counts without changing keyboard focus."
  (interactive)
  (let ((sessions (mx-machina-sessions)))
    (setq mx-machina--ui-folders (mx-machina-folders))
    (mx-machina--refresh-ui sessions)
    (when (fboundp 'mx-machina-board--refresh) (mx-machina-board--refresh))
    (dolist (name '("*M-x Machina*" "*M-x Machina Archive*"))
     (when-let* ((buffer (get-buffer name)))
      (with-current-buffer buffer
        (setq tabulated-list-entries
              (mapcar
               (lambda (s)
                 (list (mx-machina-session-id s)
                       (vector (mx-machina-session-name s) (mx-machina-session-status s)
                               (mx-machina-session-activity s) (mx-machina-session-profile s)
                               (mx-machina-session-branch s)
                               (if (mx-machina-session-conversation s) "saved" "pending")
                               (abbreviate-file-name (mx-machina-session-directory s)))))
               (if (derived-mode-p 'mx-machina-archive-mode)
                   (mx-machina-sessions 'archived) sessions)))
        (tabulated-list-print t))))))

(defvar mx-machina-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "n") #'mx-machina-new)
    (define-key map (kbd "RET") #'mx-machina-open)
    (define-key map (kbd "r") #'mx-machina-open)
    (define-key map (kbd "x") #'mx-machina-stop)
    (define-key map (kbd "a") #'mx-machina-archive)
    (define-key map (kbd "A") #'mx-machina-archived)
    (define-key map (kbd "d") #'mx-machina-delete)
    (define-key map (kbd "g") #'mx-machina-refresh)
    (define-key map (kbd "f") #'mx-machina-files)
    (define-key map (kbd "m") #'mx-machina-magit)
    (define-key map (kbd "i") #'mx-machina-details)
    (define-key map (kbd "B") #'mx-machina-board)
    (define-key map (kbd "?") #'mx-machina-actions)
    (define-key map (kbd "]") #'mx-machina-next-attention)
    (define-key map (kbd "[") #'mx-machina-previous-attention)
    (define-key map (kbd "W") #'mx-machina-rebind-worktree)
    (define-key map (kbd "e") #'mx-machina-eshell)
    (define-key map (kbd "z") #'mx-machina-focus)
    (define-key map (kbd "s") #'mx-machina)
    map))

(define-derived-mode mx-machina-mode tabulated-list-mode "Machina"
  "Dashboard for persistent coding-agent sessions."
  (setq tabulated-list-format [("Session" 20 t) ("Process" 10 t) ("Activity" 10 t)
                               ("Profile" 22 t) ("Branch" 20 t) ("Identity" 9 t)
                               ("Worktree" 0 t)]
        tabulated-list-padding 1)
  (setq-local header-line-format " n new   RET open   x stop   a archive   A archived   d delete   e eshell   g refresh")
  (add-hook 'tabulated-list-revert-hook #'mx-machina-refresh nil t)
  (tabulated-list-init-header))

(defvar mx-machina-archive-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map mx-machina-mode-map)
    (define-key map (kbd "RET") #'mx-machina-restore)
    (define-key map (kbd "r") #'mx-machina-restore)
    (define-key map (kbd "A") #'mx-machina-dashboard)
    map))

(define-derived-mode mx-machina-archive-mode mx-machina-mode "Machina Archive"
  "Archived records; RET restores without launching and d deletes only the record."
  (setq-local header-line-format " Archived agents · RET/r restore   d delete record   A active agents   q close"))

;;;###autoload
(defun mx-machina-archived ()
  "Show archived agents without launching or restoring any agent."
  (interactive)
  (mx-machina)
  (mx-machina--select-main-window)
  (switch-to-buffer (get-buffer-create "*M-x Machina Archive*"))
  (unless (derived-mode-p 'mx-machina-archive-mode) (mx-machina-archive-mode))
  (mx-machina-refresh))

;;;###autoload
(defun mx-machina-dashboard ()
  "Open the expanded session dashboard without launching agents."
  (interactive)
  (mx-machina)
  (mx-machina--select-main-window)
  (with-current-buffer (get-buffer-create "*M-x Machina*")
    (mx-machina-mode)
    (mx-machina-refresh)
    (pop-to-buffer (current-buffer))))

(require 'mx-machina-ui)

(provide 'mx-machina)
;;; mx-machina.el ends here
