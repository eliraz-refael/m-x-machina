;;; mx-machina-recovery.el --- Explicit worktree recovery -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Change only a stopped agent's saved checkout association after confirmation.
;; Keep its backend identity and leave Git and conversation files untouched.
;;; Code:
(require 'mx-machina-diagnostics)

(defun mx-machina-recovery--session (id)
  "Read ID without initializing or reconciling the registry."
  (or (seq-find (lambda (s) (equal id (mx-machina-session-id s)))
                (mx-machina-diagnostics--sessions))
      (user-error "This agent record no longer exists")))

(defun mx-machina-recovery--require-stopped (session)
  "Refuse SESSION while a run is tracked, starting or still alive."
  (let ((id (mx-machina-session-id session)))
    (when (or (gethash id mx-machina--running)
              (member (mx-machina-session-status session) '("starting" "live"))
              ;; Graceful ACP shutdown can outlive removal from --running.
              (seq-some
               (lambda (buffer)
                 (with-current-buffer buffer
                   (and (equal id mx-machina--managed-id)
                        ;; shell-maker's buffer process can be a long-lived
                        ;; UI pipe even after the ACP agent has exited.
                        (let ((process (if (eq mx-machina--backend-kind 'agent-shell)
                                           (map-nested-elt (bound-and-true-p agent-shell--state)
                                                           '(:client :process))
                                         (get-buffer-process buffer))))
                          (and process (process-live-p process))))))
               (buffer-list)))
      (user-error "Stop this agent first (x in the sidebar) and wait for its process to exit"))))

(defun mx-machina-recovery--target (directory)
  "Validate DIRECTORY and return (ROOT BRANCH PROJECT), using only Git reads."
  (pcase-let ((`(,root ,branch) (mx-machina--worktree directory)))
    (list root branch (mx-machina--project-name root))))

(defun mx-machina-recovery--apply (session target)
  "Save confirmed TARGET for SESSION after revalidating both snapshots."
  (let* ((id (mx-machina-session-id session))
         (directory (car target)))
    (unless (equal target (mx-machina-recovery--target directory))
      (user-error "The chosen checkout changed during confirmation; inspect it and try again"))
    (mx-machina-recovery--require-stopped (mx-machina-recovery--session id))
    (unless (equal session (mx-machina-recovery--session id))
      (user-error "The agent record changed during confirmation; inspect it and try again"))
    ;; Acquire registry ownership only after confirmation.  Cancelling even a
    ;; cold-registry invocation must not reconcile runs or alter observations.
    (mx-machina-store-open)
    (mx-machina--with-transaction mx-machina--db
      (unless (equal session (mx-machina-session id))
        (user-error "The agent record changed; inspect it and try again"))
      (mx-machina-recovery--require-stopped session)
      (mx-machina--exec "UPDATE sessions SET directory=?,branch=?,project=? WHERE id=?"
                         directory (nth 1 target) (nth 2 target) id))
    (unless (equal directory (mx-machina-session-directory session))
      ;; Keep old shells, jobs and drafts intact.  The next e opens a shell at
      ;; the new association instead of silently returning the old checkout.
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (equal id mx-machina--shell-id)
            (setq mx-machina--shell-id nil
                  header-line-format (format " Previous worktree shell · %s · %s"
                                             (mx-machina-session-name session) default-directory))))))
    (mx-machina-refresh)
    (when (and (derived-mode-p 'mx-machina-diagnostics-mode)
               (equal id mx-machina-diagnostics--id))
      (mx-machina-diagnostics-refresh))
    (message "Worktree association saved. Open the agent explicitly to resume its original conversation.")
    id))

;;;###autoload
(defun mx-machina-rebind-worktree (id &optional directory)
  "Confirm and save a new checkout association for stopped agent ID.
Prompt for DIRECTORY when omitted.  Keep the same directory to accept its
current branch.  Never switch branches, move files or start an agent."
  (interactive (list (mx-machina-diagnostics--read-id)))
  (let* ((session (mx-machina-recovery--session id))
         (old-directory (mx-machina-session-directory session)))
    (mx-machina-recovery--require-stopped session)
    (let* ((directory (or directory
                          (read-directory-name
                           "Associate worktree (keep directory to accept current branch): "
                           (if (file-directory-p old-directory) old-directory
                             (if (file-directory-p default-directory) default-directory temporary-file-directory))
                           nil t)))
           (target (mx-machina-recovery--target directory)))
      (if (equal target (list old-directory (mx-machina-session-branch session)
                              (mx-machina-session-project session)))
          (message "This worktree and branch are already associated with the agent")
        (unless (yes-or-no-p
                 (format (concat "Change worktree association for %s?\n"
                                 "Recorded: %s [%s]\nProposed: %s [%s]\n"
                                 "Profile and conversation ID stay the same. No files will move.\n"
                                 "Backend history may depend on the old directory. Save association? ")
                         (mx-machina-session-name session) old-directory
                         (mx-machina-session-branch session) (car target) (nth 1 target)))
          (user-error "Worktree recovery cancelled"))
        (mx-machina-recovery--apply session target)))))

(defun mx-machina-recovery--profile (session)
  "Resolve SESSION's existing profile without exposing configuration errors."
  (let ((configs (condition-case nil (mx-machina-backend-configs)
                   (error (user-error "Fix your profile definitions, reload them, and inspect diagnostics before retrying")))))
    (or (seq-find (lambda (config)
                   (equal (mx-machina-session-profile session)
                          (symbol-name (map-elt config :identifier)))) configs)
        (user-error "Restore the original profile %s and its account configuration; i explains recovery"
                    (mx-machina-session-profile session)))))

;;;###autoload
(defun mx-machina-retry (id)
  "Confirm an explicit retry of ID's saved conversation after configuration repair.
Keep the same profile and conversation ID; never create a new conversation."
  (interactive (list (mx-machina-diagnostics--read-id)))
  (let* ((session (mx-machina-recovery--session id))
         (conversation (mx-machina-session-conversation session)))
    (mx-machina-recovery--require-stopped session)
    (when (mx-machina-archived-p session) (user-error "Restore this archived record before retrying"))
    (unless (and (stringp conversation) (not (string-empty-p conversation)))
      (user-error "No saved conversation to retry; inspect the retained buffer or create a separate agent explicitly"))
    (let ((config (copy-tree (mx-machina-recovery--profile session))))
      (unless (equal (mx-machina--worktree (mx-machina-session-directory session))
                     (list (mx-machina-session-directory session) (mx-machina-session-branch session)))
        (user-error "Checkout changed; use W to review the association before retrying"))
      (unless (yes-or-no-p
               (format "Retry %s with profile %s and saved conversation %s? Confirm the original backend/account configuration is restored. "
                       (mx-machina-session-name session) (mx-machina-session-profile session) conversation))
        (user-error "Retry cancelled"))
      (unless (equal config (mx-machina-recovery--profile session))
        (user-error "Profile configuration changed during confirmation; inspect it and try again"))
      (unless (equal session (mx-machina-recovery--session id))
        (user-error "Agent record changed during confirmation; inspect it and try again"))
      (mx-machina-recovery--require-stopped session)
      ;; The normal start guards recheck the checkout and fix the transport's
      ;; expected ID.  No prompt is submitted or replayed by this command.
      (mx-machina-open id))))

(provide 'mx-machina-recovery)
;;; mx-machina-recovery.el ends here
