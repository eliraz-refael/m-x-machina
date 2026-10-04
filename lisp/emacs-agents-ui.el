;;; emacs-agents-ui.el --- Persistent overview and conversation focus -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Native side windows keep the overview and selected conversation visible.
;; Focus saves a frame's window configuration, without owning its buffers.
;;; Code:
(require 'emacs-agents-store)
(require 'emacs-agents-transport)
(require 'seq)

(declare-function emacs-agents-refresh "emacs-agents")
(declare-function emacs-agents--read-id "emacs-agents")
(declare-function emacs-agents-start "emacs-agents")
(declare-function emacs-agents-shutdown "emacs-agents")

(defcustom emacs-agents-sidebar-side 'left
  "Side of the frame for the agent overview."
  :type '(choice (const left) (const right)) :group 'emacs-agents)
(defcustom emacs-agents-sidebar-width 34
  "Preferred width of the agent overview in columns."
  :type 'integer :group 'emacs-agents)
(defcustom emacs-agents-sidebar-line-spacing 0.12
  "Extra line spacing in the sidebar; 0 keeps compact rows."
  :type 'number :group 'emacs-agents)
(defface emacs-agents-folder
  '((t :inherit font-lock-keyword-face :weight bold))
  "Logical folder headings in the sidebar." :group 'emacs-agents)

(defface emacs-agents-working
  '((((class color) (background dark)) :foreground "#51afef" :weight bold)
    (((class color) (background light)) :foreground "#005faf" :weight bold)
    (t :weight bold)) "An agent actively working." :group 'emacs-agents)
(defface emacs-agents-ready
  '((((class color) (background dark)) :foreground "#98be65")
    (((class color) (background light)) :foreground "#236b35")
    (t :inherit success)) "An idle agent ready for a prompt." :group 'emacs-agents)
(defface emacs-agents-waiting
  '((((class color) (background dark)) :foreground "#ECBE7B" :weight bold)
    (((class color) (background light)) :foreground "#875500" :weight bold)
    (t :inherit warning)) "An agent requesting input or approval." :group 'emacs-agents)
(defface emacs-agents-unread
  '((((class color) (background dark)) :foreground "#c678dd" :weight bold)
    (((class color) (background light)) :foreground "#7c3aad" :weight bold)
    (t :weight bold :underline t)) "Unseen assistant output." :group 'emacs-agents)
(defface emacs-agents-error
  '((t :inherit error :weight bold)) "A failed session." :group 'emacs-agents)
(defface emacs-agents-active-session
  '((((class color) (background dark)) :background "#343b48")
    (((class color) (background light)) :background "#e8eef5")
    (t :underline t))
  "Subtle background for the conversation displayed in the main pane."
  :group 'emacs-agents)

(defcustom emacs-agents-animate t
  "Show a small spinner for working agents.  A colored dot remains when disabled."
  :type 'boolean :group 'emacs-agents)
(defcustom emacs-agents-read-delay 5
  "Continuous seconds viewing the latest output before marking it read.
Leaving the conversation, scrolling away, losing frame focus, or receiving
new output resets the countdown.  Set to 0 for immediate acknowledgment.
Explicitly marking an agent read with `emacs-agents-mark-read' bypasses it."
  :type 'number :group 'emacs-agents)
(defvar emacs-agents--read-dwell nil
  "Current reading observation: (VIEW START-TIME LAST-CHECK-TIME).")
(defvar emacs-agents--ui-sessions nil)
(defvar emacs-agents--ui-folders nil)
(defvar emacs-agents--ui-timer nil)
(defvar emacs-agents--spinner 0)
(defvar-local emacs-agents--collapsed nil)
(defvar-local emacs-agents--identity "")
(defvar-local emacs-agents--context "")
(defvar-local emacs-agents--saved-header nil)
(defvar-local emacs-agents--saved-tab-line nil)
(defvar-local emacs-agents--header-installed nil)
(defvar emacs-agents--managed-id)
(declare-function emacs-agents-mark-read "emacs-agents")
(declare-function emacs-agents-open "emacs-agents")

(defvar emacs-agents--summary " Agents: 0")
(put 'emacs-agents--summary 'risky-local-variable t)
(defvar-local emacs-agents--expanded nil)
(defvar emacs-agents--active-session nil)
(defvar emacs-agents--conversation-buffers nil)

(defun emacs-agents--start-sidebar-observers ()
  "Track the displayed agent while an overview is in use."
  (add-hook 'window-buffer-change-functions #'emacs-agents--update-active-session)
  (add-hook 'window-selection-change-functions #'emacs-agents--update-active-session))

(defun emacs-agents--stop-sidebar-observers ()
  "Release the overview's window observers."
  (remove-hook 'window-buffer-change-functions #'emacs-agents--update-active-session)
  (remove-hook 'window-selection-change-functions #'emacs-agents--update-active-session))

(defun emacs-agents--forget-conversation-buffer ()
  "Remove this buffer from the managed header list."
  (setq emacs-agents--conversation-buffers (delq (current-buffer) emacs-agents--conversation-buffers)))

(defun emacs-agents--tree-padding (depth)
  "Indent DEPTH while reserving space for identity in narrow sidebars."
  (if (> depth 4) "      … " (make-string (* depth 2) ?\s)))

(defun emacs-agents--visible-conversation-id ()
  "Return the agent displayed in this frame's editing area."
  (let ((window (seq-find
                 (lambda (window)
                   (and (not (window-parameter window 'window-side))
                        (buffer-local-value 'emacs-agents--managed-id (window-buffer window))))
                 (window-list))))
    (when window (buffer-local-value 'emacs-agents--managed-id (window-buffer window)))))

(defun emacs-agents--update-active-session (&rest _)
  "Refresh the active marker when the displayed conversation changes."
  (when-let* ((buffer (get-buffer "*Agent Overview*")))
    (unless (equal emacs-agents--active-session (emacs-agents--visible-conversation-id))
      (with-current-buffer buffer (emacs-agents--render-sidebar emacs-agents--ui-sessions)))))

(defun emacs-agents--activity (session)
  "Return one display state for SESSION, giving process state precedence."
  (pcase (emacs-agents-session-status session)
    ("failed" "error")
    ((or "stopped" "exited") "stopped")
    ("starting" "starting")
    ("live" (pcase (emacs-agents-session-activity session)
              ("working" "working") ("approval" "approval")
              ("input" "ready") ("waiting" "waiting") (_ "unknown")))
    (_ "unknown")))

(defun emacs-agents--activity-face (state)
  "Return a face for STATE."
  (pcase state
    ((or "approval" "waiting") 'emacs-agents-waiting)
    ("error" 'emacs-agents-error)
    ("working" 'emacs-agents-working)
    ("ready" 'emacs-agents-ready)
    ((or "stopped" "unknown") 'shadow)
    (_ 'default)))

(define-minor-mode emacs-agents-status-mode
  "Show cached agent counts in the modeline, including during focus mode."
  :global t :group 'emacs-agents
  (if emacs-agents-status-mode
      (progn
        (unless (listp global-mode-string)
          (setq global-mode-string (list global-mode-string)))
        (unless (memq 'emacs-agents--summary global-mode-string)
          (setq global-mode-string
                (append global-mode-string '(emacs-agents--summary)))))
    (setq global-mode-string (remq 'emacs-agents--summary global-mode-string)))
  (force-mode-line-update t))

(defun emacs-agents--sidebar-id ()
  "Return the session identity at point in the sidebar."
  (get-text-property (point) 'emacs-agents-id))

(defun emacs-agents--sidebar-node ()
  "Return the agent or folder node at point."
  (get-text-property (point) 'emacs-agents-node))

(defun emacs-agents--sidebar-position (id)
  "Return the start of session ID's sidebar entry, if it exists."
  (when id
    (let ((position (point-min)))
      (while (and (< position (point-max))
                  (not (equal id (get-text-property position 'emacs-agents-node))))
        (setq position (next-single-property-change position 'emacs-agents-node nil (point-max))))
      (when (< position (point-max)) position))))

(defun emacs-agents--sidebar-anchor (position)
  "Capture POSITION relative to its session so refresh can preserve it."
  (let* ((id (get-text-property position 'emacs-agents-node))
         (start (emacs-agents--sidebar-position id)))
    (list id (if start (- position start) 0) position)))

(defun emacs-agents--sidebar-resolve (anchor)
  "Resolve a saved ANCHOR after rendering the sidebar."
  (pcase-let ((`(,id ,offset ,fallback) anchor))
    (if-let* ((start (emacs-agents--sidebar-position id)))
        (min (+ start offset)
             (1- (next-single-property-change start 'emacs-agents-node nil (point-max))))
      (min fallback (point-max)))))

(defun emacs-agents--state-label (session)
  "Return a colored state label for SESSION, optionally animated."
  (let ((state (emacs-agents--activity session)))
    (propertize
     (concat (when (and emacs-agents-animate (equal state "working"))
               (concat (aref ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
                             (% emacs-agents--spinner 10)) " "))
             "[" (upcase state) "]")
     'face (emacs-agents--activity-face state))))

(defun emacs-agents--insert-session (session depth)
  "Insert SESSION at logical nesting DEPTH."
  (let* ((sid (emacs-agents-session-id session))
         (directory (emacs-agents-session-directory session))
         (expanded (member sid emacs-agents--expanded))
         (padding (emacs-agents--tree-padding depth))
         (state (emacs-agents--activity session))
         (start (point)))
    (insert padding (if expanded "▾ " "▸ ")
            (propertize
             (if (and emacs-agents-animate (equal state "working"))
                 (aref ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"] (% emacs-agents--spinner 10))
               "●")
             'face (emacs-agents--activity-face state)) " "
            (if (emacs-agents-unread-p session)
                (propertize "* " 'face 'emacs-agents-unread) "")
            (propertize (emacs-agents-session-name session)
                        'face (if (emacs-agents-unread-p session) 'emacs-agents-unread 'default))
            "\n")
    (when (equal sid emacs-agents--active-session)
      (add-face-text-property (+ start (length padding)) (1- (point))
                              'emacs-agents-active-session t))
    (when expanded
      (let ((details-start (point)))
      (insert padding "  State: " (emacs-agents--state-label session)
              "\n" padding "  Dir: " (abbreviate-file-name directory)
              "\n" padding "  Branch: " (emacs-agents-session-branch session)
              "\n" padding "  Profile: " (emacs-agents-session-profile session)
              "\n" padding "  Model: " (or (emacs-agents-session-model session) "not reported")
              "\n" padding "  Identity: " (if (emacs-agents-session-conversation session) "saved" "pending") "\n")
      (add-face-text-property details-start (point) 'shadow t)))
    (add-text-properties start (point)
                         (list 'emacs-agents-id sid 'emacs-agents-node sid
                               'help-echo (format "%s · %s%s\nFolder: %s\n%s"
                                                  (emacs-agents-session-name session) state
                                                  (if (emacs-agents-unread-p session) " · unread" "")
                                                  (or (emacs-agents-session-folder session) "") directory)
                               'emacs-agents-folder (or (emacs-agents-session-folder session) "")
                               'rear-nonsticky t))))

(defun emacs-agents--in-folder-p (session folder)
  "Return whether SESSION is inside FOLDER or one of its descendants."
  (let ((path (or (emacs-agents-session-folder session) "")))
    (or (equal path folder) (string-prefix-p (concat folder "/") path))))

(defun emacs-agents--insert-tree (sessions)
  "Insert logical folders and SESSIONS with no fixed nesting limit."
  (dolist (session sessions)
    (when (string-empty-p (or (emacs-agents-session-folder session) ""))
      (emacs-agents--insert-session session 0)))
  (dolist (folder emacs-agents--ui-folders)
    (unless (seq-some (lambda (closed) (string-prefix-p (concat closed "/") folder))
                      emacs-agents--collapsed)
      (let* ((parts (split-string folder "/" t))
             (depth (1- (length parts)))
             (members (seq-filter (lambda (session) (emacs-agents--in-folder-p session folder)) sessions))
             (working (seq-count (lambda (session) (equal (emacs-agents--activity session) "working")) members))
             (waiting (seq-count (lambda (session) (member (emacs-agents--activity session) '("waiting" "approval"))) members))
             (unread (seq-count #'emacs-agents-unread-p members))
             (start (point)))
        (when (and (= depth 0) (not (bobp)))
          (insert "\n")
          (setq start (point)))
        (insert (emacs-agents--tree-padding depth)
                (if (member folder emacs-agents--collapsed) "▸ " "▾ ")
                (propertize (car (last parts)) 'face 'emacs-agents-folder)
                (propertize (format " (%d)" (length members)) 'face 'shadow)
                (if (> working 0) (propertize (format " %d working" working) 'face 'emacs-agents-working) "")
                (if (> waiting 0) (propertize (format " %d waiting" waiting) 'face 'emacs-agents-waiting) "")
                (if (> unread 0) (propertize (format " ● %d NEW" unread) 'face 'emacs-agents-unread) "") "\n")
        (add-text-properties start (point)
                             (list 'emacs-agents-folder folder 'emacs-agents-node (concat "folder:" folder)
                                   'help-echo folder
                                   'rear-nonsticky t))
        (unless (member folder emacs-agents--collapsed)
          (dolist (session sessions)
            (when (equal folder (emacs-agents-session-folder session))
              (emacs-agents--insert-session session (1+ depth)))))))))

(defun emacs-agents--render-sidebar (sessions)
  "Render SESSIONS while retaining selection, expansion and visible positions."
  (setq emacs-agents--active-session (emacs-agents--visible-conversation-id))
  (let* ((anchor (emacs-agents--sidebar-anchor (point)))
         (windows (mapcar
                   (lambda (window)
                     (list window
                           (emacs-agents--sidebar-anchor (window-point window))
                           (emacs-agents--sidebar-anchor (window-start window))))
                   (get-buffer-window-list (current-buffer) nil t)))
         (inhibit-read-only t))
    (erase-buffer)
    (if (and (null sessions) (null emacs-agents--ui-folders))
        (insert "No sessions yet.\n\nPress n for an agent; N for a folder.\n")
      (emacs-agents--insert-tree sessions))
    (goto-char (emacs-agents--sidebar-resolve anchor))
    (dolist (saved windows)
      (pcase-let ((`(,window ,position ,start) saved))
        (when (window-live-p window)
          (set-window-point window (emacs-agents--sidebar-resolve position))
          (set-window-start window (emacs-agents--sidebar-resolve start) t))))))

(defun emacs-agents--refresh-ui (sessions)
  "Update overview and cached modeline counts using SESSIONS."
  (setq emacs-agents--ui-sessions sessions)
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (session sessions)
      (let ((state (emacs-agents--activity session)))
        (puthash state (1+ (gethash state counts 0)) counts)))
    (setq emacs-agents--summary
          (concat " Agents: "
                  (if (null sessions) "0"
                    (mapconcat
                     (lambda (state)
                       (propertize (format "%d %s" (gethash state counts) state)
                                   'face (emacs-agents--activity-face state)))
                     (seq-filter (lambda (state) (gethash state counts))
                                 '("working" "ready" "waiting" "approval" "starting" "stopped" "unknown" "error"))
                     " · ")))))
  (when-let* ((buffer (get-buffer "*Agent Overview*")))
    (with-current-buffer buffer (emacs-agents--render-sidebar sessions)))
  (let ((unread (seq-count #'emacs-agents-unread-p sessions)))
    (when (> unread 0)
      (setq emacs-agents--summary
            (concat emacs-agents--summary (propertize (format " · %d unread" unread) 'face 'emacs-agents-unread)))))
  (emacs-agents--refresh-headers)
  (if (seq-some (lambda (session) (or (equal (emacs-agents--activity session) "working")
                                     (emacs-agents-unread-p session))) sessions)
      (progn
        (add-hook 'post-command-hook #'emacs-agents--maybe-read-current)
        (add-hook 'window-selection-change-functions #'emacs-agents--read-view-changed)
        (add-hook 'window-buffer-change-functions #'emacs-agents--read-view-changed)
        (add-function :after after-focus-change-function #'emacs-agents--read-view-changed)
        (unless emacs-agents--ui-timer
          (setq emacs-agents--ui-timer (run-at-time 0.25 0.25 #'emacs-agents--ui-tick))))
    (emacs-agents--stop-ui-timer))
  (force-mode-line-update t))

(defun emacs-agents-sidebar-next (&optional previous)
  "Move to the next session, or the previous one when PREVIOUS is non-nil."
  (interactive)
  (let ((id (emacs-agents--sidebar-node))
        (origin (point))
        (step (if previous -1 1)))
    (forward-line step)
    (while (and (not (if previous (bobp) (eobp)))
                (or (null (emacs-agents--sidebar-node))
                    (equal id (emacs-agents--sidebar-node))))
      (forward-line step))
    (if (or (null (emacs-agents--sidebar-node))
            (equal id (emacs-agents--sidebar-node)))
        (goto-char origin)
      (goto-char (emacs-agents--sidebar-position (emacs-agents--sidebar-node))))))

(defun emacs-agents-sidebar-previous ()
  "Move to the previous session."
  (interactive)
  (emacs-agents-sidebar-next t))

(defun emacs-agents-sidebar-expand ()
  "Toggle a folder or agent details without launching anything."
  (interactive)
  (let ((id (emacs-agents--sidebar-id))
        (folder (get-text-property (point) 'emacs-agents-folder)))
    (cond
     (id (setq emacs-agents--expanded
               (if (member id emacs-agents--expanded) (delete id emacs-agents--expanded)
                 (cons id emacs-agents--expanded))))
     (folder (setq emacs-agents--collapsed
                   (if (member folder emacs-agents--collapsed) (delete folder emacs-agents--collapsed)
                     (cons folder emacs-agents--collapsed))))
     (t (user-error "Move to an agent or folder first")))
    (emacs-agents--render-sidebar emacs-agents--ui-sessions)))

(defun emacs-agents-sidebar-open ()
  "Open the selected agent or toggle the selected folder."
  (interactive)
  (if (emacs-agents--sidebar-id)
      (emacs-agents-open (emacs-agents--sidebar-id))
    (emacs-agents-sidebar-expand)))

(defvar emacs-agents-sidebar-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (binding '(("n" . emacs-agents-new) ("RET" . emacs-agents-sidebar-open)
                       ("r" . emacs-agents-open) ("x" . emacs-agents-stop)
                       ("a" . emacs-agents-archive) ("A" . emacs-agents-archived)
                       ("d" . emacs-agents-delete)
                       ("g" . emacs-agents-refresh) ("f" . emacs-agents-files)
                       ("m" . emacs-agents-magit) ("i" . emacs-agents-details)
                       ("W" . emacs-agents-rebind-worktree)
                       ("B" . emacs-agents-board)
                       ("?" . emacs-agents-actions)
                       ("]" . emacs-agents-next-attention) ("[" . emacs-agents-previous-attention)
                       ("e" . emacs-agents-eshell)
                       ("TAB" . emacs-agents-sidebar-expand) ("z" . emacs-agents-focus)
                       ("j" . emacs-agents-sidebar-next) ("k" . emacs-agents-sidebar-previous)
                       ("<down>" . emacs-agents-sidebar-next) ("<up>" . emacs-agents-sidebar-previous)
                       ("D" . emacs-agents-dashboard) ("c" . emacs-agents-close-view)
                       ("N" . emacs-agents-new-folder) ("M" . emacs-agents-move)
                       ("R" . emacs-agents-rename) ("u" . emacs-agents-mark-read)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map))

(define-derived-mode emacs-agents-sidebar-mode special-mode "Agent Overview"
  "Persistent session overview.  TAB expands; RET opens; z focuses; D lists all."
  (setq-local truncate-lines t
              line-spacing emacs-agents-sidebar-line-spacing
              cursor-type 'box
              header-line-format " M-x Machina · ? actions · B board"
              emacs-agents--expanded nil
              emacs-agents--collapsed nil)
  (hl-line-mode 1)
  (emacs-agents--start-sidebar-observers)
  (add-hook 'kill-buffer-hook #'emacs-agents--stop-sidebar-observers nil t)
  (add-hook 'change-major-mode-hook #'emacs-agents--stop-sidebar-observers nil t))

(defun emacs-agents--refresh-headers (&optional visible-only)
  "Refresh cached native header rows without changing conversation text."
  (setq emacs-agents--conversation-buffers (seq-filter #'buffer-live-p emacs-agents--conversation-buffers))
  (dolist (buffer (if visible-only
                     (seq-filter (lambda (buffer) (get-buffer-window buffer 'visible))
                                 emacs-agents--conversation-buffers)
                   emacs-agents--conversation-buffers))
    (with-current-buffer buffer
      (when (bound-and-true-p emacs-agents-conversation-mode)
        (when-let* ((session (seq-find (lambda (s) (equal emacs-agents--managed-id (emacs-agents-session-id s)))
                                       emacs-agents--ui-sessions)))
          (let* ((project (or (emacs-agents-session-project session)
                              (file-name-nondirectory (directory-file-name (emacs-agents-session-directory session)))))
                 (identity (concat " " (emacs-agents--state-label session) " "
                                   (emacs-agents-session-name session) " · Project: " project
                                   " · Interface: " (symbol-name emacs-agents--backend-kind)
                                   " · Model: " (or (emacs-agents-session-model session) "not reported")))
                 (context (format " Worktree: %s · Branch: %s · Folder: %s"
                                  (abbreviate-file-name (emacs-agents-session-directory session))
                                  (emacs-agents-session-branch session)
                                  (let ((folder (emacs-agents-session-folder session)))
                                    (if (or (null folder) (string-empty-p folder)) "root" folder)))))
            (setq emacs-agents--identity (propertize identity 'help-echo identity)
                  emacs-agents--context (propertize context 'help-echo context)
                  tab-line-format '(:eval emacs-agents--identity)
                  header-line-format '(:eval emacs-agents--context))))))))

(defun emacs-agents--conversation-reading-p (buffer)
  "Return non-nil when the user is viewing BUFFER's latest output."
  (let ((window (selected-window)))
    (and (eq (window-buffer window) buffer)
         (eq (frame-visible-p (window-frame window)) t)
         (or (not (display-graphic-p (window-frame window)))
             (frame-focus-state (window-frame window)))
         (with-current-buffer buffer
           (let ((position (if emacs-agents--read-position-function
                               (funcall emacs-agents--read-position-function)
                             (max (point-min) (1- (point-max))))))
             (and position (pos-visible-in-window-p position window)))))))

(defun emacs-agents--reset-read-dwell (&optional id)
  "Reset the reading countdown, optionally only for session ID."
  (when (or (null id) (equal id (nth 2 (car emacs-agents--read-dwell))))
    (setq emacs-agents--read-dwell nil)))

(defun emacs-agents--read-view-changed (&rest _)
  "Observe window or frame-focus changes, including brief visits elsewhere."
  (emacs-agents--maybe-read-current))

(defun emacs-agents--maybe-read-current ()
  "Acknowledge output after a continuous, visible reading interval."
  (let* ((buffer (window-buffer (selected-window)))
         (id (buffer-local-value 'emacs-agents--managed-id buffer))
         (session (and id (seq-find (lambda (s) (equal id (emacs-agents-session-id s))) emacs-agents--ui-sessions))))
    (if (not (and session (emacs-agents-unread-p session)
                  (emacs-agents--conversation-reading-p buffer)))
        (emacs-agents--reset-read-dwell)
      (let ((view (list (selected-window) buffer id))
            (now (float-time)))
        ;; A long gap may be system sleep or a blocked event loop: it is not
        ;; evidence of continuous reading.  The heartbeat normally runs at 4 Hz.
        (when (or (not (equal view (car emacs-agents--read-dwell)))
                  (> (- now (nth 2 emacs-agents--read-dwell)) 1)
                  (< now (nth 2 emacs-agents--read-dwell)))
          (setq emacs-agents--read-dwell (list view now now)))
        (setf (nth 2 emacs-agents--read-dwell) now)
        (when (>= (- now (nth 1 emacs-agents--read-dwell))
                  (max 0 emacs-agents-read-delay))
          (emacs-agents--reset-read-dwell)
          (emacs-agents-mark-read id))))))

(defun emacs-agents--stop-ui-timer ()
  "Stop the UI heartbeat without touching agents."
  (when emacs-agents--ui-timer (cancel-timer emacs-agents--ui-timer))
  (setq emacs-agents--ui-timer nil)
  (remove-hook 'post-command-hook #'emacs-agents--maybe-read-current)
  (remove-hook 'window-selection-change-functions #'emacs-agents--read-view-changed)
  (remove-hook 'window-buffer-change-functions #'emacs-agents--read-view-changed)
  (remove-function after-focus-change-function #'emacs-agents--read-view-changed)
  (emacs-agents--reset-read-dwell))

(defun emacs-agents--ui-tick ()
  "Animate visible working agents from cache and check read visibility."
  (emacs-agents--maybe-read-current)
  (when (and emacs-agents-animate
             (seq-some (lambda (s) (equal (emacs-agents--activity s) "working")) emacs-agents--ui-sessions))
    (setq emacs-agents--spinner (1+ emacs-agents--spinner))
    (when-let* ((buffer (get-buffer "*Agent Overview*"))
                ((get-buffer-window buffer 'visible)))
      (with-current-buffer buffer (emacs-agents--render-sidebar emacs-agents--ui-sessions)))
    (emacs-agents--refresh-headers t)
    (force-mode-line-update t)))

(defun emacs-agents--restore-layout ()
  "Restore this frame's saved layout and return non-nil if it was focused."
  (when-let* ((configuration (frame-parameter nil 'emacs-agents-focus-layout)))
    (set-window-configuration configuration)
    (set-frame-parameter nil 'emacs-agents-focus-layout nil)
    t))

;;;###autoload
(defun emacs-agents ()
  "Show the persistent overview without starting agents, leaving focus mode."
  (interactive)
  (emacs-agents--restore-layout)
  (emacs-agents-store-open)
  (add-hook 'kill-emacs-hook #'emacs-agents-shutdown)
  (emacs-agents-status-mode 1)
  (emacs-agents--start-sidebar-observers)
  (let ((buffer (get-buffer-create "*Agent Overview*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'emacs-agents-sidebar-mode)
        (emacs-agents-sidebar-mode)))
    (emacs-agents-refresh)
    (select-window
     (display-buffer
      buffer `((display-buffer-in-side-window)
               (side . ,emacs-agents-sidebar-side) (slot . 1)
               (window-width . ,emacs-agents-sidebar-width)
               (window-parameters . ((no-delete-other-windows . t))))))
    (unless (emacs-agents--sidebar-node)
      (goto-char (point-min))
      (emacs-agents-sidebar-next))))

(defun emacs-agents--select-main-window ()
  "Select an ordinary editing window, keeping agent side windows intact."
  (when-let* ((window (seq-find (lambda (w) (not (window-parameter w 'window-side)))
                               (window-list))))
    (select-window window)))

(defun emacs-agents--show-conversation (buffer)
  "Show BUFFER in the entire editing area beside the sidebar.
Save the previous layout once, so switching agents does not replace it."
  (with-current-buffer buffer (emacs-agents-conversation-mode 1))
  (if (frame-parameter nil 'emacs-agents-focus-layout)
      (switch-to-buffer buffer)
    (emacs-agents)
    ;; Retire conversation side windows left by the earlier prototype.
    (dolist (window (window-list))
      (when (and (window-parameter window 'window-side)
                 (buffer-local-value 'emacs-agents-conversation-mode (window-buffer window)))
        (delete-window window)))
    (unless (frame-parameter nil 'emacs-agents-conversation-layout)
      (set-frame-parameter nil 'emacs-agents-conversation-layout
                           (current-window-configuration)))
    (emacs-agents--select-main-window)
    (dolist (window (window-list))
      (unless (or (eq window (selected-window))
                  (window-parameter window 'window-side))
        (delete-window window)))
    (switch-to-buffer buffer))
  (emacs-agents--update-active-session))

;;;###autoload
(defun emacs-agents-close-view ()
  "Close the conversation view, restoring the preceding editor layout.
Keep the agent process, conversation buffer and unsent draft intact."
  (interactive)
  (emacs-agents--restore-layout)
  (when-let* ((configuration (frame-parameter nil 'emacs-agents-conversation-layout)))
    (set-window-configuration configuration)
    (set-frame-parameter nil 'emacs-agents-conversation-layout nil))
  (emacs-agents))

;;;###autoload
(defun emacs-agents-focus (&optional id)
  "Focus session ID, or restore this frame's previous window layout.
Sending a prompt never leaves focus automatically.  C-c C-z toggles from a
managed conversation; the sidebar and dashboard also bind z."
  (interactive (list (unless (frame-parameter nil 'emacs-agents-focus-layout)
                       (emacs-agents--read-id))))
  (unless (emacs-agents--restore-layout)
    (let ((buffer (emacs-agents-start (or id (emacs-agents--read-id)))))
      ;; Ensure there is an overview to return to, even when invoked directly.
      (unless (get-buffer-window "*Agent Overview*" (selected-frame))
        (save-selected-window (emacs-agents)))
      (set-frame-parameter nil 'emacs-agents-focus-layout (current-window-configuration))
      (condition-case err
          (let ((ignore-window-parameters t))
            (emacs-agents--select-main-window)
            (delete-other-windows)
            (switch-to-buffer buffer)
            (message "Agent focus: C-c C-z restores your layout"))
        (error (emacs-agents--restore-layout) (signal (car err) (cdr err)))))))

(defvar emacs-agents-conversation-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-z") #'emacs-agents-focus)
    (define-key map (kbd "C-c C-q") #'emacs-agents-close-view)
    (define-key map (kbd "C-c ?") #'emacs-agents-actions)
    map))

(define-minor-mode emacs-agents-conversation-mode
  "Provide focus and close-view commands in managed conversations."
  :lighter nil :keymap emacs-agents-conversation-mode-map
  (if emacs-agents-conversation-mode
      (progn
        (cl-pushnew (current-buffer) emacs-agents--conversation-buffers)
        (add-hook 'kill-buffer-hook #'emacs-agents--forget-conversation-buffer nil t)
        (add-hook 'change-major-mode-hook #'emacs-agents--forget-conversation-buffer nil t)
        (unless emacs-agents--header-installed
          (setq emacs-agents--saved-header header-line-format
                emacs-agents--saved-tab-line tab-line-format
                emacs-agents--header-installed t))
        (emacs-agents--refresh-headers))
    (emacs-agents--forget-conversation-buffer)
    (setq header-line-format emacs-agents--saved-header
          tab-line-format emacs-agents--saved-tab-line
          emacs-agents--header-installed nil)
    (remove-hook 'post-command-hook #'emacs-agents--maybe-read-current t)))

(provide 'emacs-agents-ui)
;;; emacs-agents-ui.el ends here
