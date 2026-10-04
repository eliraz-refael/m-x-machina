;;; emacs-agents-recovery.el --- Explicit worktree recovery -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Change only a stopped agent's saved checkout association after confirmation.
;; Keep its backend identity and leave Git and conversation files untouched.
;;; Code:
(require 'emacs-agents-diagnostics)

(defun emacs-agents-recovery--session (id)
  "Read ID without initializing or reconciling the registry."
  (or (seq-find (lambda (s) (equal id (emacs-agents-session-id s)))
                (emacs-agents-diagnostics--sessions))
      (user-error "This agent record no longer exists")))

(defun emacs-agents-recovery--require-stopped (session)
  "Refuse SESSION while a run is tracked, starting or still alive."
  (let ((id (emacs-agents-session-id session)))
    (when (or (gethash id emacs-agents--running)
              (member (emacs-agents-session-status session) '("starting" "live"))
              ;; Graceful ACP shutdown can outlive removal from --running.
              (seq-some
               (lambda (buffer)
                 (with-current-buffer buffer
                   (and (equal id emacs-agents--managed-id)
                        ;; shell-maker's buffer process can be a long-lived
                        ;; UI pipe even after the ACP agent has exited.
                        (let ((process (if (eq emacs-agents--backend-kind 'agent-shell)
                                           (map-nested-elt (bound-and-true-p agent-shell--state)
                                                           '(:client :process))
                                         (get-buffer-process buffer))))
                          (and process (process-live-p process))))))
               (buffer-list)))
      (user-error "Stop this agent first (x in the sidebar) and wait for its process to exit"))))

(defun emacs-agents-recovery--target (directory)
  "Validate DIRECTORY and return (ROOT BRANCH PROJECT), using only Git reads."
  (pcase-let ((`(,root ,branch) (emacs-agents--worktree directory)))
    (list root branch (emacs-agents--project-name root))))

(defun emacs-agents-recovery--apply (session target)
  "Save confirmed TARGET for SESSION after revalidating both snapshots."
  (let* ((id (emacs-agents-session-id session))
         (directory (car target)))
    (unless (equal target (emacs-agents-recovery--target directory))
      (user-error "The chosen checkout changed during confirmation; inspect it and try again"))
    (emacs-agents-recovery--require-stopped (emacs-agents-recovery--session id))
    (unless (equal session (emacs-agents-recovery--session id))
      (user-error "The agent record changed during confirmation; inspect it and try again"))
    ;; Acquire registry ownership only after confirmation.  Cancelling even a
    ;; cold-registry invocation must not reconcile runs or alter observations.
    (emacs-agents-store-open)
    (with-sqlite-transaction emacs-agents--db
      (unless (equal session (emacs-agents-session id))
        (user-error "The agent record changed; inspect it and try again"))
      (emacs-agents-recovery--require-stopped session)
      (emacs-agents--exec "UPDATE sessions SET directory=?,branch=?,project=? WHERE id=?"
                         directory (nth 1 target) (nth 2 target) id))
    (unless (equal directory (emacs-agents-session-directory session))
      ;; Keep old shells, jobs and drafts intact.  The next e opens a shell at
      ;; the new association instead of silently returning the old checkout.
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (equal id emacs-agents--shell-id)
            (setq emacs-agents--shell-id nil
                  header-line-format (format " Previous worktree shell · %s · %s"
                                             (emacs-agents-session-name session) default-directory))))))
    (emacs-agents-refresh)
    (when (and (derived-mode-p 'emacs-agents-diagnostics-mode)
               (equal id emacs-agents-diagnostics--id))
      (emacs-agents-diagnostics-refresh))
    (message "Worktree association saved. Open the agent explicitly to resume its original conversation.")
    id))

;;;###autoload
(defun emacs-agents-rebind-worktree (id &optional directory)
  "Confirm and save a new checkout association for stopped agent ID.
Prompt for DIRECTORY when omitted.  Keep the same directory to accept its
current branch.  Never switch branches, move files or start an agent."
  (interactive (list (emacs-agents-diagnostics--read-id)))
  (let* ((session (emacs-agents-recovery--session id))
         (old-directory (emacs-agents-session-directory session)))
    (emacs-agents-recovery--require-stopped session)
    (let* ((directory (or directory
                          (read-directory-name
                           "Associate worktree (keep directory to accept current branch): "
                           (if (file-directory-p old-directory) old-directory
                             (if (file-directory-p default-directory) default-directory temporary-file-directory))
                           nil t)))
           (target (emacs-agents-recovery--target directory)))
      (if (equal target (list old-directory (emacs-agents-session-branch session)
                              (emacs-agents-session-project session)))
          (message "This worktree and branch are already associated with the agent")
        (unless (yes-or-no-p
                 (format (concat "Change worktree association for %s?\n"
                                 "Recorded: %s [%s]\nProposed: %s [%s]\n"
                                 "Profile and conversation ID stay the same. No files will move.\n"
                                 "Backend history may depend on the old directory. Save association? ")
                         (emacs-agents-session-name session) old-directory
                         (emacs-agents-session-branch session) (car target) (nth 1 target)))
          (user-error "Worktree recovery cancelled"))
        (emacs-agents-recovery--apply session target)))))

(defun emacs-agents-recovery--profile (session)
  "Resolve SESSION's existing profile without exposing configuration errors."
  (let ((configs (condition-case nil (emacs-agents-backend-configs)
                   (error (user-error "Fix your profile definitions, reload them, and inspect diagnostics before retrying")))))
    (or (seq-find (lambda (config)
                   (equal (emacs-agents-session-profile session)
                          (symbol-name (map-elt config :identifier)))) configs)
        (user-error "Restore the original profile %s and its account configuration; i explains recovery"
                    (emacs-agents-session-profile session)))))

;;;###autoload
(defun emacs-agents-retry (id)
  "Confirm an explicit retry of ID's saved conversation after configuration repair.
Keep the same profile and conversation ID; never create a new conversation."
  (interactive (list (emacs-agents-diagnostics--read-id)))
  (let* ((session (emacs-agents-recovery--session id))
         (conversation (emacs-agents-session-conversation session)))
    (emacs-agents-recovery--require-stopped session)
    (when (emacs-agents-archived-p session) (user-error "Restore this archived record before retrying"))
    (unless (and (stringp conversation) (not (string-empty-p conversation)))
      (user-error "No saved conversation to retry; inspect the retained buffer or create a separate agent explicitly"))
    (let ((config (copy-tree (emacs-agents-recovery--profile session))))
      (unless (equal (emacs-agents--worktree (emacs-agents-session-directory session))
                     (list (emacs-agents-session-directory session) (emacs-agents-session-branch session)))
        (user-error "Checkout changed; use W to review the association before retrying"))
      (unless (yes-or-no-p
               (format "Retry %s with profile %s and saved conversation %s? Confirm the original backend/account configuration is restored. "
                       (emacs-agents-session-name session) (emacs-agents-session-profile session) conversation))
        (user-error "Retry cancelled"))
      (unless (equal config (emacs-agents-recovery--profile session))
        (user-error "Profile configuration changed during confirmation; inspect it and try again"))
      (unless (equal session (emacs-agents-recovery--session id))
        (user-error "Agent record changed during confirmation; inspect it and try again"))
      (emacs-agents-recovery--require-stopped session)
      ;; The normal start guards recheck the checkout and fix the transport's
      ;; expected ID.  No prompt is submitted or replayed by this command.
      (emacs-agents-open id))))

(provide 'emacs-agents-recovery)
;;; emacs-agents-recovery.el ends here
