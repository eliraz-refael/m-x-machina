;;; mx-machina-actions.el --- Contextual agent actions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; A temporary menu with a pinned target and state checks at dispatch time.
;;; Code:
(require 'mx-machina-recovery)
(require 'button)
(defvar mx-machina-board--selection)
(declare-function mx-machina-board--render "mx-machina-board")
(declare-function mx-machina-board-open "mx-machina-board")
(defvar-local mx-machina-actions--id nil)
(defvar-local mx-machina-actions--folder nil)
(defvar-local mx-machina-actions--origin nil)
(defvar-local mx-machina-actions--window nil)
(defvar-local mx-machina-actions--point nil)

(defun mx-machina-actions--session ()
  "Read the pinned record without initializing or reconciling the registry."
  (when mx-machina-actions--id
    (seq-find (lambda (s) (equal mx-machina-actions--id (mx-machina-session-id s)))
              (mx-machina-diagnostics--sessions))))

(defun mx-machina-actions--entries (session)
  "Return (KEY LABEL COMMAND REASON) entries appropriate for SESSION.
A non-nil REASON disables the action.  Do not launch or change anything."
  (let* ((absent (unless session (if mx-machina-actions--id "Agent record was deleted" "Select an agent first")))
         (archived (and session (mx-machina-archived-p session)))
         (restore-first (and archived "Restore this archived agent first"))
         (running (and session (gethash (mx-machina-session-id session) mx-machina--running)))
         (stop-first (when session
                       (condition-case err (progn (mx-machina-recovery--require-stopped session) nil)
                         (user-error (error-message-string err)))))
         (no-history (and session (not (mx-machina-session-conversation session)) "No saved conversation; inspect diagnostics"))
         (bad-directory (and session
                             (or (file-remote-p (mx-machina-session-directory session))
                                 (not (file-directory-p (mx-machina-session-directory session))))
                             "Worktree unavailable; use W to repair its association")))
    (list
     (list "o" (if running "Open conversation" "Start / resume conversation") 'mx-machina-open
           (or absent restore-first (and (not running) session (mx-machina-session-run session) no-history)))
     (list "x" "Stop process" 'mx-machina-stop (or absent (unless running "No tracked process to stop")))
     (list "r" "Retry saved conversation" 'mx-machina-retry (or absent restore-first stop-first no-history))
     (list "i" "Diagnostics and recovery guidance" 'mx-machina-details absent)
     (list "W" "Change worktree association" 'mx-machina-rebind-worktree (or absent stop-first))
     (list "R" "Rename agent" 'mx-machina-rename absent)
     (list "M" "Move agent to folder" 'mx-machina-move absent)
     (list "u" "Mark output read" 'mx-machina-mark-read
           (or absent (unless (and session (mx-machina-unread-p session)) "No unread output")))
     (list "e" "Associated eshell" 'mx-machina-eshell (or absent bad-directory))
     (list "f" "Worktree files" 'mx-machina-files (or absent bad-directory))
     (list "a" (if running "Stop and archive…" "Archive agent") 'mx-machina-archive
           (or absent (and archived "Already archived") (and (not running) stop-first)))
     (list "s" "Restore archived agent" 'mx-machina-restore (or absent (unless archived "Agent is already active")))
     (list "d" (if running "Stop and delete record…" "Delete record…") 'mx-machina-delete
           (or absent (and (not running) stop-first)))
     (list "TAB" "Expand / collapse folder" 'mx-machina-sidebar-expand
           (unless (and (not mx-machina-actions--id) mx-machina-actions--folder
                        (buffer-live-p mx-machina-actions--origin)
                        (with-current-buffer mx-machina-actions--origin (derived-mode-p 'mx-machina-sidebar-mode)))
             "Select a sidebar folder"))
     (list "n" "New agent…" 'mx-machina-new nil)
     (list "N" "New folder…" 'mx-machina-new-folder nil)
     (list "B" "Agent board" 'mx-machina-board nil)
     (list "D" "Full dashboard" 'mx-machina-dashboard nil)
     (list "A" "Archived agents" 'mx-machina-archived nil)
     (list "]" "Next agent needing attention" 'mx-machina-next-attention nil)
     (list "[" "Previous agent needing attention" 'mx-machina-previous-attention nil))))

(defun mx-machina-actions-refresh ()
  "Refresh the menu's labels and availability, retaining its original target."
  (interactive)
  (let ((session (mx-machina-actions--session))
        (position (point)) (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (cond (session (format "%s · %s%s" (mx-machina-session-name session)
                                              (mx-machina--activity session)
                                              (if (mx-machina-archived-p session) " · archived" "")))
                             (mx-machina-actions--id "Agent record deleted")
                             (mx-machina-actions--folder (concat "Folder: " mx-machina-actions--folder))
                             (t "Agent actions")) 'face 'bold)
            "\nKeys below apply inside this menu. RET or click runs a highlighted action.\n\n")
    (dolist (entry (mx-machina-actions--entries session))
      (pcase-let ((`(,key ,label ,_command ,reason) entry))
        (if reason
            (insert (propertize (format "%4s  %-34s  %s\n" key label reason) 'face 'shadow))
          (insert-text-button (format "%4s  %s" key label)
                              'action (lambda (_) (mx-machina-actions--run key))
                              'follow-link t 'face 'link)
          (insert "\n"))))
    (goto-char (min position (point-max)))
    (set-buffer-modified-p nil)))

(defun mx-machina-actions-close ()
  "Dismiss the menu and return to its originating view."
  (interactive)
  (let ((origin mx-machina-actions--origin) (window mx-machina-actions--window)
        (menu-window (get-buffer-window (current-buffer))))
    (when menu-window (quit-window nil menu-window))
    (when (and (window-live-p window) (buffer-live-p origin))
      (select-window window)
      (switch-to-buffer origin))))

(defun mx-machina-actions--run (key)
  "Revalidate KEY and invoke its existing command against the pinned target."
  (let* ((entry (assoc key (mx-machina-actions--entries (mx-machina-actions--session))))
         (command (nth 2 entry)) (reason (nth 3 entry))
         (id mx-machina-actions--id) (folder mx-machina-actions--folder)
         (origin mx-machina-actions--origin) (position mx-machina-actions--point))
    (unless entry (user-error "No action for this key"))
    (when reason (mx-machina-actions-refresh) (user-error "%s" reason))
    (unless (buffer-live-p origin) (user-error "The original view was closed; reopen the action menu"))
    (mx-machina-actions-close)
    (with-current-buffer origin
      ;; Rendering may have moved the source row while the menu was open.
      (cond
       ((derived-mode-p 'mx-machina-sidebar-mode)
        (let ((p (mx-machina--sidebar-position (or id (and folder (concat "folder:" folder))))))
          (when (and (eq command 'mx-machina-sidebar-expand) (not p))
            (user-error "The folder is no longer visible; select it and reopen the menu"))
          (when p (goto-char p))))
       ((and id (derived-mode-p 'mx-machina-board-mode))
        (setq mx-machina-board--selection id)
        (mx-machina-board--render))
       ((and position (marker-position position)) (goto-char (min (marker-position position) (point-max)))))
      ;; Keep the existing interactive confirmations for archive/delete.  Both
      ;; ID readers are pinned, so a moving row cannot redirect those commands.
      (cl-letf (((symbol-function 'mx-machina--read-id) (lambda () (or id (user-error "Select an agent first"))))
                ((symbol-function 'mx-machina-diagnostics--read-id) (lambda () (or id (user-error "Select an agent first")))))
        (cond
         ((eq command 'mx-machina-restore) (mx-machina-restore id))
         ((and (eq command 'mx-machina-open) (derived-mode-p 'mx-machina-board-mode))
          (unless (equal id (get-text-property (point) 'mx-machina-id))
            (user-error "The agent is outside this board scope; choose its folder and reopen the menu"))
          (mx-machina-board-open))
         (t (call-interactively command)))))))

(defun mx-machina-actions-dispatch ()
  "Invoke the menu action bound to the pressed key."
  (interactive)
  (mx-machina-actions--run (key-description (this-command-keys-vector))))

(defun mx-machina-actions-activate ()
  "Activate the action button on the current line."
  (interactive)
  (let ((button (or (button-at (point))
                    (next-button (line-beginning-position) t))))
    (unless (and button (< (button-start button) (line-end-position)))
      (user-error "Choose an enabled action"))
    (button-activate button)))

(defvar mx-machina-actions-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (key '("o" "x" "r" "i" "W" "R" "M" "u" "e" "f" "a" "s" "d" "TAB" "n" "N" "B" "D" "A" "]" "["))
      (define-key map (kbd key) #'mx-machina-actions-dispatch))
    (define-key map (kbd "RET") #'mx-machina-actions-activate)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "g") #'mx-machina-actions-refresh)
    (define-key map (kbd "q") #'mx-machina-actions-close)
    (define-key map (kbd "?") #'mx-machina-actions-close)
    map))
(define-derived-mode mx-machina-actions-mode special-mode "Machina Actions"
  "Contextual actions; disabled entries explain their prerequisites."
  (setq-local truncate-lines nil header-line-format " Actions · letter or RET runs · g refresh · q closes")
  (visual-line-mode 1))

;;;###autoload
(defun mx-machina-actions ()
  "Show contextual actions without starting, stopping or acknowledging an agent."
  (interactive)
  (if (derived-mode-p 'mx-machina-actions-mode)
      (mx-machina-actions-refresh)
    (let ((origin (current-buffer)) (window (selected-window)) (position (point-marker))
          (id (or (get-text-property (point) 'mx-machina-id)
                  (and (derived-mode-p 'mx-machina-mode) (tabulated-list-get-id))
                  (and (derived-mode-p 'mx-machina-diagnostics-mode) mx-machina-diagnostics--id)
                  mx-machina--managed-id mx-machina--shell-id))
          (folder (get-text-property (point) 'mx-machina-folder))
          (buffer (get-buffer-create "*M-x Machina Actions*")))
      (with-current-buffer buffer
        (mx-machina-actions-mode)
        (setq mx-machina-actions--id id mx-machina-actions--folder folder
              mx-machina-actions--origin origin mx-machina-actions--window window
              mx-machina-actions--point position)
        (mx-machina-actions-refresh)
        (when-let* ((button (next-button (point-min)))) (goto-char (button-start button))))
      (select-window (display-buffer-in-side-window buffer '((side . bottom) (slot . 2) (window-height . 0.45)))))))

(provide 'mx-machina-actions)
;;; mx-machina-actions.el ends here
