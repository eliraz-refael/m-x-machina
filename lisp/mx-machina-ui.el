;;; mx-machina-ui.el --- Persistent overview and conversation focus -*- lexical-binding: t; -*-

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
;; Native side windows keep the overview and selected conversation visible.
;; Focus saves a frame's window configuration, without owning its buffers.
;;; Code:
(require 'mx-machina-store)
(require 'mx-machina-transport)
(require 'seq)

(declare-function mx-machina-refresh "mx-machina")
(declare-function mx-machina--read-id "mx-machina")
(declare-function mx-machina-start "mx-machina")
(declare-function mx-machina-shutdown "mx-machina")

(defcustom mx-machina-sidebar-side 'left
  "Side of the frame for the agent overview."
  :type '(choice (const left) (const right)) :group 'mx-machina)
(defcustom mx-machina-sidebar-width 34
  "Preferred width of the agent overview in columns."
  :type 'integer :group 'mx-machina)
(defcustom mx-machina-sidebar-line-spacing 0.12
  "Extra line spacing in the sidebar; 0 keeps compact rows."
  :type 'number :group 'mx-machina)
(defface mx-machina-folder
  '((t :inherit font-lock-keyword-face :weight bold))
  "Logical folder headings in the sidebar." :group 'mx-machina)

(defface mx-machina-working
  '((((class color) (background dark)) :foreground "#51afef" :weight bold)
    (((class color) (background light)) :foreground "#005faf" :weight bold)
    (t :weight bold)) "An agent actively working." :group 'mx-machina)
(defface mx-machina-ready
  '((((class color) (background dark)) :foreground "#98be65")
    (((class color) (background light)) :foreground "#236b35")
    (t :inherit success)) "An idle agent ready for a prompt." :group 'mx-machina)
(defface mx-machina-waiting
  '((((class color) (background dark)) :foreground "#ECBE7B" :weight bold)
    (((class color) (background light)) :foreground "#875500" :weight bold)
    (t :inherit warning)) "An agent requesting input or approval." :group 'mx-machina)
(defface mx-machina-unread
  '((((class color) (background dark)) :foreground "#c678dd" :weight bold)
    (((class color) (background light)) :foreground "#7c3aad" :weight bold)
    (t :weight bold :underline t)) "Unseen assistant output." :group 'mx-machina)
(defface mx-machina-error
  '((t :inherit error :weight bold)) "A failed session." :group 'mx-machina)
(defface mx-machina-active-session
  '((((class color) (background dark)) :background "#343b48")
    (((class color) (background light)) :background "#e8eef5")
    (t :underline t))
  "Subtle background for the conversation displayed in the main pane."
  :group 'mx-machina)

(defcustom mx-machina-animate t
  "Show a small spinner for working agents.  A colored dot remains when disabled."
  :type 'boolean :group 'mx-machina)
(defcustom mx-machina-read-delay 5
  "Continuous seconds viewing the latest output before marking it read.
Leaving the conversation, scrolling away, losing frame focus, or receiving
new output resets the countdown.  Set to 0 for immediate acknowledgment.
Explicitly marking an agent read with `mx-machina-mark-read' bypasses it."
  :type 'number :group 'mx-machina)
(defvar mx-machina--read-dwell nil
  "Current reading observation: (VIEW START-TIME LAST-CHECK-TIME).")
(defvar mx-machina--ui-sessions nil)
(defvar mx-machina--ui-folders nil)
(defvar mx-machina--ui-timer nil)
(defvar mx-machina--spinner 0)
(defvar-local mx-machina--collapsed nil)
(defvar-local mx-machina--identity "")
(defvar-local mx-machina--context "")
(defvar-local mx-machina--saved-header nil)
(defvar-local mx-machina--saved-tab-line nil)
(defvar-local mx-machina--header-installed nil)
(defvar mx-machina--managed-id)
(declare-function mx-machina-mark-read "mx-machina")
(declare-function mx-machina-open "mx-machina")

(defvar mx-machina--summary " Agents: 0")
(put 'mx-machina--summary 'risky-local-variable t)
(defvar-local mx-machina--expanded nil)
(defvar mx-machina--active-session nil)
(defvar mx-machina--conversation-buffers nil)

(defun mx-machina--start-sidebar-observers ()
  "Track the displayed agent while an overview is in use."
  (add-hook 'window-buffer-change-functions #'mx-machina--update-active-session)
  (add-hook 'window-selection-change-functions #'mx-machina--update-active-session))

(defun mx-machina--stop-sidebar-observers ()
  "Release the overview's window observers."
  (remove-hook 'window-buffer-change-functions #'mx-machina--update-active-session)
  (remove-hook 'window-selection-change-functions #'mx-machina--update-active-session))

(defun mx-machina--forget-conversation-buffer ()
  "Remove this buffer from the managed header list."
  (setq mx-machina--conversation-buffers (delq (current-buffer) mx-machina--conversation-buffers)))

(defun mx-machina--tree-padding (depth)
  "Indent DEPTH while reserving space for identity in narrow sidebars."
  (if (> depth 4) "      … " (make-string (* depth 2) ?\s)))

(defun mx-machina--visible-conversation-id ()
  "Return the agent displayed in this frame's editing area."
  (let ((window (seq-find
                 (lambda (window)
                   (and (not (window-parameter window 'window-side))
                        (buffer-local-value 'mx-machina--managed-id (window-buffer window))))
                 (window-list))))
    (when window (buffer-local-value 'mx-machina--managed-id (window-buffer window)))))

(defun mx-machina--update-active-session (&rest _)
  "Refresh the active marker when the displayed conversation changes."
  (when-let* ((buffer (get-buffer "*M-x Machina Sidebar*")))
    (unless (equal mx-machina--active-session (mx-machina--visible-conversation-id))
      (with-current-buffer buffer (mx-machina--render-sidebar mx-machina--ui-sessions)))))

(defun mx-machina--activity (session)
  "Return one display state for SESSION, giving process state precedence."
  (pcase (mx-machina-session-status session)
    ("failed" "error")
    ((or "stopped" "exited") "stopped")
    ("starting" "starting")
    ("live" (pcase (mx-machina-session-activity session)
              ("working" "working") ("approval" "approval")
              ("input" "ready") ("waiting" "waiting") (_ "unknown")))
    (_ "unknown")))

(defun mx-machina--activity-face (state)
  "Return a face for STATE."
  (pcase state
    ((or "approval" "waiting") 'mx-machina-waiting)
    ("error" 'mx-machina-error)
    ("working" 'mx-machina-working)
    ("ready" 'mx-machina-ready)
    ((or "stopped" "unknown") 'shadow)
    (_ 'default)))

;;;###autoload (autoload 'mx-machina-status-mode "mx-machina" nil t)
(define-minor-mode mx-machina-status-mode
  "Show cached agent counts in the modeline, including during focus mode."
  :global t :group 'mx-machina
  (if mx-machina-status-mode
      (progn
        (unless (listp global-mode-string)
          (setq global-mode-string (list global-mode-string)))
        (unless (memq 'mx-machina--summary global-mode-string)
          (setq global-mode-string
                (append global-mode-string '(mx-machina--summary)))))
    (setq global-mode-string (remq 'mx-machina--summary global-mode-string)))
  (force-mode-line-update t))

(defun mx-machina--sidebar-id ()
  "Return the session identity at point in the sidebar."
  (get-text-property (point) 'mx-machina-id))

(defun mx-machina--sidebar-node ()
  "Return the agent or folder node at point."
  (get-text-property (point) 'mx-machina-node))

(defun mx-machina--sidebar-position (id)
  "Return the start of session ID's sidebar entry, if it exists."
  (when id
    (let ((position (point-min)))
      (while (and (< position (point-max))
                  (not (equal id (get-text-property position 'mx-machina-node))))
        (setq position (next-single-property-change position 'mx-machina-node nil (point-max))))
      (when (< position (point-max)) position))))

(defun mx-machina--sidebar-anchor (position)
  "Capture POSITION relative to its session so refresh can preserve it."
  (let* ((id (get-text-property position 'mx-machina-node))
         (start (mx-machina--sidebar-position id)))
    (list id (if start (- position start) 0) position)))

(defun mx-machina--sidebar-resolve (anchor)
  "Resolve a saved ANCHOR after rendering the sidebar."
  (pcase-let ((`(,id ,offset ,fallback) anchor))
    (if-let* ((start (mx-machina--sidebar-position id)))
        (min (+ start offset)
             (1- (next-single-property-change start 'mx-machina-node nil (point-max))))
      (min fallback (point-max)))))

(defun mx-machina--state-label (session)
  "Return a colored state label for SESSION, optionally animated."
  (let ((state (mx-machina--activity session)))
    (propertize
     (concat (when (and mx-machina-animate (equal state "working"))
               (concat (aref ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
                             (% mx-machina--spinner 10)) " "))
             "[" (upcase state) "]")
     'face (mx-machina--activity-face state))))

(defun mx-machina--insert-session (session depth)
  "Insert SESSION at logical nesting DEPTH."
  (let* ((sid (mx-machina-session-id session))
         (directory (mx-machina-session-directory session))
         (expanded (member sid mx-machina--expanded))
         (padding (mx-machina--tree-padding depth))
         (state (mx-machina--activity session))
         (start (point)))
    (insert padding (if expanded "▾ " "▸ ")
            (propertize
             (if (and mx-machina-animate (equal state "working"))
                 (aref ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"] (% mx-machina--spinner 10))
               "●")
             'face (mx-machina--activity-face state)) " "
            (if (mx-machina-unread-p session)
                (propertize "* " 'face 'mx-machina-unread) "")
            (propertize (mx-machina-session-name session)
                        'face (if (mx-machina-unread-p session) 'mx-machina-unread 'default))
            "\n")
    (when (equal sid mx-machina--active-session)
      (add-face-text-property (+ start (length padding)) (1- (point))
                              'mx-machina-active-session t))
    (when expanded
      (let ((details-start (point)))
      (insert padding "  State: " (mx-machina--state-label session)
              "\n" padding "  Dir: " (abbreviate-file-name directory)
              "\n" padding "  Branch: " (mx-machina-session-branch session)
              "\n" padding "  Profile: " (mx-machina-session-profile session)
              "\n" padding "  Model: " (or (mx-machina-session-model session) "not reported")
              "\n" padding "  Identity: " (if (mx-machina-session-conversation session) "saved" "pending") "\n")
      (add-face-text-property details-start (point) 'shadow t)))
    (add-text-properties start (point)
                         (list 'mx-machina-id sid 'mx-machina-node sid
                               'help-echo (format "%s · %s%s\nFolder: %s\n%s"
                                                  (mx-machina-session-name session) state
                                                  (if (mx-machina-unread-p session) " · unread" "")
                                                  (or (mx-machina-session-folder session) "") directory)
                               'mx-machina-folder (or (mx-machina-session-folder session) "")
                               'rear-nonsticky t))))

(defun mx-machina--in-folder-p (session folder)
  "Return whether SESSION is inside FOLDER or one of its descendants."
  (let ((path (or (mx-machina-session-folder session) "")))
    (or (equal path folder) (string-prefix-p (concat folder "/") path))))

(defun mx-machina--insert-tree (sessions)
  "Insert logical folders and SESSIONS with no fixed nesting limit."
  (dolist (session sessions)
    (when (string-empty-p (or (mx-machina-session-folder session) ""))
      (mx-machina--insert-session session 0)))
  (dolist (folder mx-machina--ui-folders)
    (unless (seq-some (lambda (closed) (string-prefix-p (concat closed "/") folder))
                      mx-machina--collapsed)
      (let* ((parts (split-string folder "/" t))
             (depth (1- (length parts)))
             (members (seq-filter (lambda (session) (mx-machina--in-folder-p session folder)) sessions))
             (working (seq-count (lambda (session) (equal (mx-machina--activity session) "working")) members))
             (waiting (seq-count (lambda (session) (member (mx-machina--activity session) '("waiting" "approval"))) members))
             (unread (seq-count #'mx-machina-unread-p members))
             (start (point)))
        (when (and (= depth 0) (not (bobp)))
          (insert "\n")
          (setq start (point)))
        (insert (mx-machina--tree-padding depth)
                (if (member folder mx-machina--collapsed) "▸ " "▾ ")
                (propertize (car (last parts)) 'face 'mx-machina-folder)
                (propertize (format " (%d)" (length members)) 'face 'shadow)
                (if (> working 0) (propertize (format " %d working" working) 'face 'mx-machina-working) "")
                (if (> waiting 0) (propertize (format " %d waiting" waiting) 'face 'mx-machina-waiting) "")
                (if (> unread 0) (propertize (format " ● %d NEW" unread) 'face 'mx-machina-unread) "") "\n")
        (add-text-properties start (point)
                             (list 'mx-machina-folder folder 'mx-machina-node (concat "folder:" folder)
                                   'help-echo folder
                                   'rear-nonsticky t))
        (unless (member folder mx-machina--collapsed)
          (dolist (session sessions)
            (when (equal folder (mx-machina-session-folder session))
              (mx-machina--insert-session session (1+ depth)))))))))

(defun mx-machina--render-sidebar (sessions)
  "Render SESSIONS while retaining selection, expansion and visible positions."
  (setq mx-machina--active-session (mx-machina--visible-conversation-id))
  (let* ((anchor (mx-machina--sidebar-anchor (point)))
         (windows (mapcar
                   (lambda (window)
                     (list window
                           (mx-machina--sidebar-anchor (window-point window))
                           (mx-machina--sidebar-anchor (window-start window))))
                   (get-buffer-window-list (current-buffer) nil t)))
         (inhibit-read-only t))
    (erase-buffer)
    (if (and (null sessions) (null mx-machina--ui-folders))
        (insert "No sessions yet.\n\nPress n for an agent; N for a folder.\n")
      (mx-machina--insert-tree sessions))
    (goto-char (mx-machina--sidebar-resolve anchor))
    (dolist (saved windows)
      (pcase-let ((`(,window ,position ,start) saved))
        (when (window-live-p window)
          (set-window-point window (mx-machina--sidebar-resolve position))
          (set-window-start window (mx-machina--sidebar-resolve start) t))))))

(defun mx-machina--refresh-ui (sessions)
  "Update overview and cached modeline counts using SESSIONS."
  (setq mx-machina--ui-sessions sessions)
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (session sessions)
      (let ((state (mx-machina--activity session)))
        (puthash state (1+ (gethash state counts 0)) counts)))
    (setq mx-machina--summary
          (concat " Agents: "
                  (if (null sessions) "0"
                    (mapconcat
                     (lambda (state)
                       (propertize (format "%d %s" (gethash state counts) state)
                                   'face (mx-machina--activity-face state)))
                     (seq-filter (lambda (state) (gethash state counts))
                                 '("working" "ready" "waiting" "approval" "starting" "stopped" "unknown" "error"))
                     " · ")))))
  (when-let* ((buffer (get-buffer "*M-x Machina Sidebar*")))
    (with-current-buffer buffer (mx-machina--render-sidebar sessions)))
  (let ((unread (seq-count #'mx-machina-unread-p sessions)))
    (when (> unread 0)
      (setq mx-machina--summary
            (concat mx-machina--summary (propertize (format " · %d unread" unread) 'face 'mx-machina-unread)))))
  (mx-machina--refresh-headers)
  (if (seq-some (lambda (session) (or (equal (mx-machina--activity session) "working")
                                     (mx-machina-unread-p session))) sessions)
      (progn
        (add-hook 'post-command-hook #'mx-machina--maybe-read-current)
        (add-hook 'window-selection-change-functions #'mx-machina--read-view-changed)
        (add-hook 'window-buffer-change-functions #'mx-machina--read-view-changed)
        (add-function :after after-focus-change-function #'mx-machina--read-view-changed)
        (unless mx-machina--ui-timer
          (setq mx-machina--ui-timer (run-at-time 0.25 0.25 #'mx-machina--ui-tick))))
    (mx-machina--stop-ui-timer))
  (force-mode-line-update t))

(defun mx-machina-sidebar-next (&optional previous)
  "Move to the next session, or the previous one when PREVIOUS is non-nil."
  (interactive)
  (let ((id (mx-machina--sidebar-node))
        (origin (point))
        (step (if previous -1 1)))
    (forward-line step)
    (while (and (not (if previous (bobp) (eobp)))
                (or (null (mx-machina--sidebar-node))
                    (equal id (mx-machina--sidebar-node))))
      (forward-line step))
    (if (or (null (mx-machina--sidebar-node))
            (equal id (mx-machina--sidebar-node)))
        (goto-char origin)
      (goto-char (mx-machina--sidebar-position (mx-machina--sidebar-node))))))

(defun mx-machina-sidebar-previous ()
  "Move to the previous session."
  (interactive)
  (mx-machina-sidebar-next t))

(defun mx-machina-sidebar-expand ()
  "Toggle a folder or agent details without launching anything."
  (interactive)
  (let ((id (mx-machina--sidebar-id))
        (folder (get-text-property (point) 'mx-machina-folder)))
    (cond
     (id (setq mx-machina--expanded
               (if (member id mx-machina--expanded) (delete id mx-machina--expanded)
                 (cons id mx-machina--expanded))))
     (folder (setq mx-machina--collapsed
                   (if (member folder mx-machina--collapsed) (delete folder mx-machina--collapsed)
                     (cons folder mx-machina--collapsed))))
     (t (user-error "Move to an agent or folder first")))
    (mx-machina--render-sidebar mx-machina--ui-sessions)))

(defun mx-machina-sidebar-open ()
  "Open the selected agent or toggle the selected folder."
  (interactive)
  (if (mx-machina--sidebar-id)
      (mx-machina-open (mx-machina--sidebar-id))
    (mx-machina-sidebar-expand)))

(defvar mx-machina-sidebar-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (binding '(("n" . mx-machina-new) ("RET" . mx-machina-sidebar-open)
                       ("r" . mx-machina-open) ("x" . mx-machina-stop)
                       ("a" . mx-machina-archive) ("A" . mx-machina-archived)
                       ("d" . mx-machina-delete)
                       ("g" . mx-machina-refresh) ("f" . mx-machina-files)
                       ("m" . mx-machina-magit) ("i" . mx-machina-details)
                       ("W" . mx-machina-rebind-worktree)
                       ("B" . mx-machina-board)
                       ("?" . mx-machina-actions)
                       ("]" . mx-machina-next-attention) ("[" . mx-machina-previous-attention)
                       ("e" . mx-machina-eshell)
                       ("TAB" . mx-machina-sidebar-expand) ("z" . mx-machina-focus)
                       ("j" . mx-machina-sidebar-next) ("k" . mx-machina-sidebar-previous)
                       ("<down>" . mx-machina-sidebar-next) ("<up>" . mx-machina-sidebar-previous)
                       ("D" . mx-machina-dashboard) ("c" . mx-machina-close-view)
                       ("N" . mx-machina-new-folder) ("M" . mx-machina-move)
                       ("R" . mx-machina-rename) ("u" . mx-machina-mark-read)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map))

(define-derived-mode mx-machina-sidebar-mode special-mode "Machina Sidebar"
  "Persistent session overview.  TAB expands; RET opens; z focuses; D lists all."
  (setq-local truncate-lines t
              line-spacing mx-machina-sidebar-line-spacing
              cursor-type 'box
              header-line-format " M-x Machina · ? actions · B board"
              mx-machina--expanded nil
              mx-machina--collapsed nil)
  (hl-line-mode 1)
  (mx-machina--start-sidebar-observers)
  (add-hook 'kill-buffer-hook #'mx-machina--stop-sidebar-observers nil t)
  (add-hook 'change-major-mode-hook #'mx-machina--stop-sidebar-observers nil t))

(defun mx-machina--refresh-headers (&optional visible-only)
  "Refresh cached native header rows without changing conversation text.
When VISIBLE-ONLY is non-nil, refresh only displayed conversations."
  (setq mx-machina--conversation-buffers (seq-filter #'buffer-live-p mx-machina--conversation-buffers))
  (dolist (buffer (if visible-only
                     (seq-filter (lambda (buffer) (get-buffer-window buffer 'visible))
                                 mx-machina--conversation-buffers)
                   mx-machina--conversation-buffers))
    (with-current-buffer buffer
      (when (bound-and-true-p mx-machina-conversation-mode)
        (when-let* ((session (seq-find (lambda (s) (equal mx-machina--managed-id (mx-machina-session-id s)))
                                       mx-machina--ui-sessions)))
          (let* ((project (or (mx-machina-session-project session)
                              (file-name-nondirectory (directory-file-name (mx-machina-session-directory session)))))
                 (identity (concat " " (mx-machina--state-label session) " "
                                   (mx-machina-session-name session) " · Project: " project
                                   " · Interface: " (symbol-name mx-machina--backend-kind)
                                   " · Model: " (or (mx-machina-session-model session) "not reported")))
                 (context (format " Worktree: %s · Branch: %s · Folder: %s"
                                  (abbreviate-file-name (mx-machina-session-directory session))
                                  (mx-machina-session-branch session)
                                  (let ((folder (mx-machina-session-folder session)))
                                    (if (or (null folder) (string-empty-p folder)) "root" folder)))))
            (setq mx-machina--identity (propertize identity 'help-echo identity)
                  mx-machina--context (propertize context 'help-echo context)
                  tab-line-format '(:eval mx-machina--identity)
                  header-line-format '(:eval mx-machina--context))))))))

(defun mx-machina--conversation-reading-p (buffer)
  "Return non-nil when the user is viewing BUFFER's latest output."
  (let ((window (selected-window)))
    (and (eq (window-buffer window) buffer)
         (eq (frame-visible-p (window-frame window)) t)
         (or (not (display-graphic-p (window-frame window)))
             (frame-focus-state (window-frame window)))
         (with-current-buffer buffer
           (let ((position (if mx-machina--read-position-function
                               (funcall mx-machina--read-position-function)
                             (max (point-min) (1- (point-max))))))
             (and position (pos-visible-in-window-p position window)))))))

(defun mx-machina--reset-read-dwell (&optional id)
  "Reset the reading countdown, optionally only for session ID."
  (when (or (null id) (equal id (nth 2 (car mx-machina--read-dwell))))
    (setq mx-machina--read-dwell nil)))

(defun mx-machina--read-view-changed (&rest _)
  "Observe window or frame focus changes, including brief visits elsewhere."
  (mx-machina--maybe-read-current))

(defun mx-machina--maybe-read-current ()
  "Acknowledge output after a continuous, visible reading interval."
  (let* ((buffer (window-buffer (selected-window)))
         (id (buffer-local-value 'mx-machina--managed-id buffer))
         (session (and id (seq-find (lambda (s) (equal id (mx-machina-session-id s))) mx-machina--ui-sessions))))
    (if (not (and session (mx-machina-unread-p session)
                  (mx-machina--conversation-reading-p buffer)))
        (mx-machina--reset-read-dwell)
      (let ((view (list (selected-window) buffer id))
            (now (float-time)))
        ;; A long gap may be system sleep or a blocked event loop: it is not
        ;; evidence of continuous reading.  The heartbeat normally runs at 4 Hz.
        (when (or (not (equal view (car mx-machina--read-dwell)))
                  (> (- now (nth 2 mx-machina--read-dwell)) 1)
                  (< now (nth 2 mx-machina--read-dwell)))
          (setq mx-machina--read-dwell (list view now now)))
        (setf (nth 2 mx-machina--read-dwell) now)
        (when (>= (- now (nth 1 mx-machina--read-dwell))
                  (max 0 mx-machina-read-delay))
          (mx-machina--reset-read-dwell)
          (mx-machina-mark-read id))))))

(defun mx-machina--stop-ui-timer ()
  "Stop the UI heartbeat without touching agents."
  (when mx-machina--ui-timer (cancel-timer mx-machina--ui-timer))
  (setq mx-machina--ui-timer nil)
  (remove-hook 'post-command-hook #'mx-machina--maybe-read-current)
  (remove-hook 'window-selection-change-functions #'mx-machina--read-view-changed)
  (remove-hook 'window-buffer-change-functions #'mx-machina--read-view-changed)
  (remove-function after-focus-change-function #'mx-machina--read-view-changed)
  (mx-machina--reset-read-dwell))

(defun mx-machina--ui-tick ()
  "Animate visible working agents from cache and check read visibility."
  (mx-machina--maybe-read-current)
  (when (and mx-machina-animate
             (seq-some (lambda (s) (equal (mx-machina--activity s) "working")) mx-machina--ui-sessions))
    (setq mx-machina--spinner (1+ mx-machina--spinner))
    (when-let* ((buffer (get-buffer "*M-x Machina Sidebar*"))
                ((get-buffer-window buffer 'visible)))
      (with-current-buffer buffer (mx-machina--render-sidebar mx-machina--ui-sessions)))
    (mx-machina--refresh-headers t)
    (force-mode-line-update t)))

(defun mx-machina--restore-layout ()
  "Restore this frame's saved layout and return non-nil if it was focused."
  (when-let* ((configuration (frame-parameter nil 'mx-machina-focus-layout)))
    (set-window-configuration configuration)
    (set-frame-parameter nil 'mx-machina-focus-layout nil)
    t))

;;;###autoload (autoload 'mx-machina "mx-machina" nil t)
(defun mx-machina ()
  "Show the persistent overview without starting agents, leaving focus mode."
  (interactive)
  (mx-machina--restore-layout)
  (mx-machina-store-open)
  (add-hook 'kill-emacs-hook #'mx-machina-shutdown)
  (mx-machina-status-mode 1)
  (mx-machina--start-sidebar-observers)
  (let ((buffer (get-buffer-create "*M-x Machina Sidebar*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'mx-machina-sidebar-mode)
        (mx-machina-sidebar-mode)))
    (mx-machina-refresh)
    (select-window
     (display-buffer
      buffer `((display-buffer-in-side-window)
               (side . ,mx-machina-sidebar-side) (slot . 1)
               (window-width . ,mx-machina-sidebar-width)
               (window-parameters . ((no-delete-other-windows . t))))))
    (unless (mx-machina--sidebar-node)
      (goto-char (point-min))
      (mx-machina-sidebar-next))))

(defun mx-machina--select-main-window ()
  "Select an ordinary editing window, keeping agent side windows intact."
  (when-let* ((window (seq-find (lambda (w) (not (window-parameter w 'window-side)))
                               (window-list))))
    (select-window window)))

(defun mx-machina--show-conversation (buffer)
  "Show BUFFER in the entire editing area beside the sidebar.
Save the previous layout once, so switching agents does not replace it."
  (with-current-buffer buffer (mx-machina-conversation-mode 1))
  (if (frame-parameter nil 'mx-machina-focus-layout)
      (switch-to-buffer buffer)
    (mx-machina)
    ;; Retire conversation side windows left by the earlier prototype.
    (dolist (window (window-list))
      (when (and (window-parameter window 'window-side)
                 (buffer-local-value 'mx-machina-conversation-mode (window-buffer window)))
        (delete-window window)))
    (unless (frame-parameter nil 'mx-machina-conversation-layout)
      (set-frame-parameter nil 'mx-machina-conversation-layout
                           (current-window-configuration)))
    (mx-machina--select-main-window)
    (dolist (window (window-list))
      (unless (or (eq window (selected-window))
                  (window-parameter window 'window-side))
        (delete-window window)))
    (switch-to-buffer buffer))
  (mx-machina--update-active-session))

;;;###autoload (autoload 'mx-machina-close-view "mx-machina" nil t)
(defun mx-machina-close-view ()
  "Close the conversation view, restoring the preceding editor layout.
Keep the agent process, conversation buffer and unsent draft intact."
  (interactive)
  (mx-machina--restore-layout)
  (when-let* ((configuration (frame-parameter nil 'mx-machina-conversation-layout)))
    (set-window-configuration configuration)
    (set-frame-parameter nil 'mx-machina-conversation-layout nil))
  (mx-machina))

;;;###autoload (autoload 'mx-machina-focus "mx-machina" nil t)
(defun mx-machina-focus (&optional id)
  "Focus session ID, or restore this frame's previous window layout.
Sending a prompt never leaves focus automatically.
Call this command again to restore the previous layout."
  (interactive (list (unless (frame-parameter nil 'mx-machina-focus-layout)
                       (mx-machina--read-id))))
  (unless (mx-machina--restore-layout)
    (let ((buffer (mx-machina-start (or id (mx-machina--read-id)))))
      ;; Ensure there is an overview to return to, even when invoked directly.
      (unless (get-buffer-window "*M-x Machina Sidebar*" (selected-frame))
        (save-selected-window (mx-machina)))
      (set-frame-parameter nil 'mx-machina-focus-layout (current-window-configuration))
      (condition-case err
          (let ((ignore-window-parameters t))
            (mx-machina--select-main-window)
            (delete-other-windows)
            (switch-to-buffer buffer)
            (message "Agent focus: C-c C-z restores your layout"))
        (error (mx-machina--restore-layout) (signal (car err) (cdr err)))))))

(defvar mx-machina-conversation-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-z") #'mx-machina-focus)
    (define-key map (kbd "C-c C-q") #'mx-machina-close-view)
    (define-key map (kbd "C-c ?") #'mx-machina-actions)
    map))

(define-minor-mode mx-machina-conversation-mode
  "Provide focus and close-view commands in managed conversations."
  :lighter nil :keymap mx-machina-conversation-mode-map
  (if mx-machina-conversation-mode
      (progn
        (cl-pushnew (current-buffer) mx-machina--conversation-buffers)
        (add-hook 'kill-buffer-hook #'mx-machina--forget-conversation-buffer nil t)
        (add-hook 'change-major-mode-hook #'mx-machina--forget-conversation-buffer nil t)
        (unless mx-machina--header-installed
          (setq mx-machina--saved-header header-line-format
                mx-machina--saved-tab-line tab-line-format
                mx-machina--header-installed t))
        (mx-machina--refresh-headers))
    (mx-machina--forget-conversation-buffer)
    (setq header-line-format mx-machina--saved-header
          tab-line-format mx-machina--saved-tab-line
          mx-machina--header-installed nil)
    (remove-hook 'post-command-hook #'mx-machina--maybe-read-current t)))

(provide 'mx-machina-ui)
;;; mx-machina-ui.el ends here
