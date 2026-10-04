;;; emacs-agents-actions.el --- Contextual agent actions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; A temporary menu with a pinned target and state checks at dispatch time.
;;; Code:
(require 'emacs-agents-recovery)
(require 'button)
(defvar emacs-agents-board--selection)
(declare-function emacs-agents-board--render "emacs-agents-board")
(declare-function emacs-agents-board-open "emacs-agents-board")
(defvar-local emacs-agents-actions--id nil)
(defvar-local emacs-agents-actions--folder nil)
(defvar-local emacs-agents-actions--origin nil)
(defvar-local emacs-agents-actions--window nil)
(defvar-local emacs-agents-actions--point nil)

(defun emacs-agents-actions--session ()
  "Read the pinned record without initializing or reconciling the registry."
  (when emacs-agents-actions--id
    (seq-find (lambda (s) (equal emacs-agents-actions--id (emacs-agents-session-id s)))
              (emacs-agents-diagnostics--sessions))))

(defun emacs-agents-actions--entries (session)
  "Return (KEY LABEL COMMAND REASON) entries appropriate for SESSION.
A non-nil REASON disables the action.  Do not launch or change anything."
  (let* ((absent (unless session (if emacs-agents-actions--id "Agent record was deleted" "Select an agent first")))
         (archived (and session (emacs-agents-archived-p session)))
         (restore-first (and archived "Restore this archived agent first"))
         (running (and session (gethash (emacs-agents-session-id session) emacs-agents--running)))
         (stop-first (when session
                       (condition-case err (progn (emacs-agents-recovery--require-stopped session) nil)
                         (user-error (error-message-string err)))))
         (no-history (and session (not (emacs-agents-session-conversation session)) "No saved conversation; inspect diagnostics"))
         (bad-directory (and session
                             (or (file-remote-p (emacs-agents-session-directory session))
                                 (not (file-directory-p (emacs-agents-session-directory session))))
                             "Worktree unavailable; use W to repair its association")))
    (list
     (list "o" (if running "Open conversation" "Start / resume conversation") 'emacs-agents-open
           (or absent restore-first (and (not running) session (emacs-agents-session-run session) no-history)))
     (list "x" "Stop process" 'emacs-agents-stop (or absent (unless running "No tracked process to stop")))
     (list "r" "Retry saved conversation" 'emacs-agents-retry (or absent restore-first stop-first no-history))
     (list "i" "Diagnostics and recovery guidance" 'emacs-agents-details absent)
     (list "W" "Change worktree association" 'emacs-agents-rebind-worktree (or absent stop-first))
     (list "R" "Rename agent" 'emacs-agents-rename absent)
     (list "M" "Move agent to folder" 'emacs-agents-move absent)
     (list "u" "Mark output read" 'emacs-agents-mark-read
           (or absent (unless (and session (emacs-agents-unread-p session)) "No unread output")))
     (list "e" "Associated eshell" 'emacs-agents-eshell (or absent bad-directory))
     (list "f" "Worktree files" 'emacs-agents-files (or absent bad-directory))
     (list "a" (if running "Stop and archive…" "Archive agent") 'emacs-agents-archive
           (or absent (and archived "Already archived") (and (not running) stop-first)))
     (list "s" "Restore archived agent" 'emacs-agents-restore (or absent (unless archived "Agent is already active")))
     (list "d" (if running "Stop and delete record…" "Delete record…") 'emacs-agents-delete
           (or absent (and (not running) stop-first)))
     (list "TAB" "Expand / collapse folder" 'emacs-agents-sidebar-expand
           (unless (and (not emacs-agents-actions--id) emacs-agents-actions--folder
                        (buffer-live-p emacs-agents-actions--origin)
                        (with-current-buffer emacs-agents-actions--origin (derived-mode-p 'emacs-agents-sidebar-mode)))
             "Select a sidebar folder"))
     (list "n" "New agent…" 'emacs-agents-new nil)
     (list "N" "New folder…" 'emacs-agents-new-folder nil)
     (list "B" "Agent board" 'emacs-agents-board nil)
     (list "D" "Full dashboard" 'emacs-agents-dashboard nil)
     (list "A" "Archived agents" 'emacs-agents-archived nil)
     (list "]" "Next agent needing attention" 'emacs-agents-next-attention nil)
     (list "[" "Previous agent needing attention" 'emacs-agents-previous-attention nil))))

(defun emacs-agents-actions-refresh ()
  "Refresh the menu's labels and availability, retaining its original target."
  (interactive)
  (let ((session (emacs-agents-actions--session))
        (position (point)) (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (cond (session (format "%s · %s%s" (emacs-agents-session-name session)
                                              (emacs-agents--activity session)
                                              (if (emacs-agents-archived-p session) " · archived" "")))
                             (emacs-agents-actions--id "Agent record deleted")
                             (emacs-agents-actions--folder (concat "Folder: " emacs-agents-actions--folder))
                             (t "Agent actions")) 'face 'bold)
            "\nKeys below apply inside this menu. RET or click runs a highlighted action.\n\n")
    (dolist (entry (emacs-agents-actions--entries session))
      (pcase-let ((`(,key ,label ,_command ,reason) entry))
        (if reason
            (insert (propertize (format "%4s  %-34s  %s\n" key label reason) 'face 'shadow))
          (insert-text-button (format "%4s  %s" key label)
                              'action (lambda (_) (emacs-agents-actions--run key))
                              'follow-link t 'face 'link)
          (insert "\n"))))
    (goto-char (min position (point-max)))
    (set-buffer-modified-p nil)))

(defun emacs-agents-actions-close ()
  "Dismiss the menu and return to its originating view."
  (interactive)
  (let ((origin emacs-agents-actions--origin) (window emacs-agents-actions--window)
        (menu-window (get-buffer-window (current-buffer))))
    (when menu-window (quit-window nil menu-window))
    (when (and (window-live-p window) (buffer-live-p origin))
      (select-window window)
      (switch-to-buffer origin))))

(defun emacs-agents-actions--run (key)
  "Revalidate KEY and invoke its existing command against the pinned target."
  (let* ((entry (assoc key (emacs-agents-actions--entries (emacs-agents-actions--session))))
         (command (nth 2 entry)) (reason (nth 3 entry))
         (id emacs-agents-actions--id) (folder emacs-agents-actions--folder)
         (origin emacs-agents-actions--origin) (position emacs-agents-actions--point))
    (unless entry (user-error "No action for this key"))
    (when reason (emacs-agents-actions-refresh) (user-error "%s" reason))
    (unless (buffer-live-p origin) (user-error "The original view was closed; reopen the action menu"))
    (emacs-agents-actions-close)
    (with-current-buffer origin
      ;; Rendering may have moved the source row while the menu was open.
      (cond
       ((derived-mode-p 'emacs-agents-sidebar-mode)
        (let ((p (emacs-agents--sidebar-position (or id (and folder (concat "folder:" folder))))))
          (when (and (eq command 'emacs-agents-sidebar-expand) (not p))
            (user-error "The folder is no longer visible; select it and reopen the menu"))
          (when p (goto-char p))))
       ((and id (derived-mode-p 'emacs-agents-board-mode))
        (setq emacs-agents-board--selection id)
        (emacs-agents-board--render))
       ((and position (marker-position position)) (goto-char (min (marker-position position) (point-max)))))
      ;; Keep the existing interactive confirmations for archive/delete.  Both
      ;; ID readers are pinned, so a moving row cannot redirect those commands.
      (cl-letf (((symbol-function 'emacs-agents--read-id) (lambda () (or id (user-error "Select an agent first"))))
                ((symbol-function 'emacs-agents-diagnostics--read-id) (lambda () (or id (user-error "Select an agent first")))))
        (cond
         ((eq command 'emacs-agents-restore) (emacs-agents-restore id))
         ((and (eq command 'emacs-agents-open) (derived-mode-p 'emacs-agents-board-mode))
          (unless (equal id (get-text-property (point) 'emacs-agents-id))
            (user-error "The agent is outside this board scope; choose its folder and reopen the menu"))
          (emacs-agents-board-open))
         (t (call-interactively command)))))))

(defun emacs-agents-actions-dispatch ()
  "Invoke the menu action bound to the pressed key."
  (interactive)
  (emacs-agents-actions--run (key-description (this-command-keys-vector))))

(defun emacs-agents-actions-activate ()
  "Activate the action button on the current line."
  (interactive)
  (let ((button (or (button-at (point))
                    (next-button (line-beginning-position) t))))
    (unless (and button (< (button-start button) (line-end-position)))
      (user-error "Choose an enabled action"))
    (button-activate button)))

(defvar emacs-agents-actions-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (key '("o" "x" "r" "i" "W" "R" "M" "u" "e" "f" "a" "s" "d" "TAB" "n" "N" "B" "D" "A" "]" "["))
      (define-key map (kbd key) #'emacs-agents-actions-dispatch))
    (define-key map (kbd "RET") #'emacs-agents-actions-activate)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "g") #'emacs-agents-actions-refresh)
    (define-key map (kbd "q") #'emacs-agents-actions-close)
    (define-key map (kbd "?") #'emacs-agents-actions-close)
    map))
(define-derived-mode emacs-agents-actions-mode special-mode "Agent Actions"
  "Contextual actions; disabled entries explain their prerequisites."
  (setq-local truncate-lines nil header-line-format " Actions · letter or RET runs · g refresh · q closes")
  (visual-line-mode 1))

;;;###autoload
(defun emacs-agents-actions ()
  "Show contextual actions without starting, stopping or acknowledging an agent."
  (interactive)
  (if (derived-mode-p 'emacs-agents-actions-mode)
      (emacs-agents-actions-refresh)
    (let ((origin (current-buffer)) (window (selected-window)) (position (point-marker))
          (id (or (get-text-property (point) 'emacs-agents-id)
                  (and (derived-mode-p 'emacs-agents-mode) (tabulated-list-get-id))
                  (and (derived-mode-p 'emacs-agents-diagnostics-mode) emacs-agents-diagnostics--id)
                  emacs-agents--managed-id emacs-agents--shell-id))
          (folder (get-text-property (point) 'emacs-agents-folder))
          (buffer (get-buffer-create "*Agent Actions*")))
      (with-current-buffer buffer
        (emacs-agents-actions-mode)
        (setq emacs-agents-actions--id id emacs-agents-actions--folder folder
              emacs-agents-actions--origin origin emacs-agents-actions--window window
              emacs-agents-actions--point position)
        (emacs-agents-actions-refresh)
        (when-let* ((button (next-button (point-min)))) (goto-char (button-start button))))
      (select-window (display-buffer-in-side-window buffer '((side . bottom) (slot . 2) (window-height . 0.45)))))))

(provide 'emacs-agents-actions)
;;; emacs-agents-actions.el ends here
