;;; emacs-agents-board.el --- Folder-scoped agent board -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; A native, optional overview. Cards reflect observed state, never edit it.
;;; Code:
(require 'emacs-agents)

(defface emacs-agents-board-heading
  '((t :inherit font-lock-keyword-face :weight bold))
  "Folder and lane headings." :group 'emacs-agents)
(defface emacs-agents-board-border
  '((t :inherit shadow)) "Card borders." :group 'emacs-agents)
(defface emacs-agents-board-selected
  '((t :inherit highlight)) "Selected board card." :group 'emacs-agents)

(defvar-local emacs-agents-board--scope "")
(defvar-local emacs-agents-board--selection nil)
(defvar-local emacs-agents-board--positions nil)
(defvar-local emacs-agents-board--width nil)
(defvar-local emacs-agents-board--source-layout nil)
(defvar-local emacs-agents-board--conversation-layout nil)
(defvar-local emacs-agents-board--overlays nil)
(defconst emacs-agents-board--lanes '("Working" "Waiting" "Ready" "Stopped"))

(defun emacs-agents-board--lane (session)
  "Return SESSION's observed lane, including states outside the main four."
  (pcase (emacs-agents--activity session)
    ("working" "Working") ((or "waiting" "approval") "Waiting")
    ("ready" "Ready") ((or "stopped" "error") "Stopped") (_ "Other")))

(defun emacs-agents-board--wrap (text width)
  "Split TEXT into lines no wider than WIDTH, retaining all characters."
  (let (lines)
    (while (> (string-width text) width)
      (let* ((prefix (truncate-string-to-width text width))
             (cut (length prefix)))
        ;; Prefer a word boundary without losing long unbroken names.
        (when (string-match " .*\\'" prefix)
          (when (> (match-beginning 0) (/ width 2))
            (setq cut (match-beginning 0))))
        (push (substring text 0 cut) lines)
        (setq text (string-trim-left (substring text cut)))))
    (nreverse (cons text lines))))

(defun emacs-agents-board--pad (text width)
  "Pad TEXT with spaces to WIDTH display columns."
  (concat text (make-string (max 0 (- width (string-width text))) ?\s)))

(defun emacs-agents-board--card (session width)
  "Return rendered card lines for SESSION within WIDTH columns."
  (let* ((id (emacs-agents-session-id session))
         (state (emacs-agents--activity session))
         (inside (- width 4))
         (title (mapcar (lambda (s) (propertize s 'face 'bold))
                        (emacs-agents-board--wrap (emacs-agents-session-name session) inside)))
         (status (concat (propertize (upcase state) 'face (emacs-agents--activity-face state))
                         (when (emacs-agents-unread-p session)
                           (propertize " · NEW" 'face 'emacs-agents-unread))))
         (branch (truncate-string-to-width (emacs-agents-session-branch session) inside nil nil "…"))
         (lines (append
                 (list (propertize (concat "┌" (make-string (- width 2) ?─) "┐") 'face 'emacs-agents-board-border))
                 (mapcar (lambda (line) (concat "│ " (emacs-agents-board--pad line inside) " │"))
                         (append title (list status (propertize branch 'face 'shadow))))
                 (list (propertize (concat "└" (make-string (- width 2) ?─) "┘") 'face 'emacs-agents-board-border)))))
    (mapcar (lambda (line)
              (propertize line 'emacs-agents-id id 'mouse-face 'highlight
                          'help-echo (format "%s\n%s · %s\n%s\nRET or click to open"
                                             (emacs-agents-session-name session)
                                             (emacs-agents-session-profile session) state
                                             (emacs-agents-session-directory session))
                          'rear-nonsticky t)) lines)))

(defun emacs-agents-board--highlight ()
  "Highlight all visible fragments of the selected card."
  (mapc #'delete-overlay emacs-agents-board--overlays)
  (setq emacs-agents-board--overlays nil)
  (let ((position (point-min)))
    (while (< position (point-max))
      (let ((end (next-single-property-change position 'emacs-agents-id nil (point-max))))
        (when (and emacs-agents-board--selection
                   (equal emacs-agents-board--selection (get-text-property position 'emacs-agents-id)))
          (let ((overlay (make-overlay position end)))
            (overlay-put overlay 'face 'emacs-agents-board-selected)
            (push overlay emacs-agents-board--overlays)))
        (setq position end)))))

(defun emacs-agents-board--render (&optional width)
  "Render cached sessions at WIDTH, preserving selected agent identity."
  (setq width (max 20 (or width (window-body-width (get-buffer-window (current-buffer))) 80)))
  (let* ((sessions (seq-filter
                    (lambda (s) (and (not (emacs-agents-archived-p s))
                                     (or (string-empty-p emacs-agents-board--scope)
                                         (emacs-agents--in-folder-p s emacs-agents-board--scope))))
                    emacs-agents--ui-sessions))
         (folders (sort (delete-dups (mapcar #'emacs-agents-session-folder sessions)) #'string-lessp))
         (lanes (append emacs-agents-board--lanes
                        (when (seq-some (lambda (s) (equal (emacs-agents-board--lane s) "Other")) sessions)
                          '("Other"))))
         (columns (max 1 (min 4 (/ (+ width 2) 26))))
         (cell-width (/ (- width (* 2 (1- columns))) columns))
         (old-point (point))
         (inhibit-read-only t))
    (setq emacs-agents-board--width width emacs-agents-board--positions nil)
    (erase-buffer)
    (insert (propertize "M-X MACHINA\n" 'face 'emacs-agents-board-heading))
    (dolist (line (emacs-agents-board--wrap
                   (format "%s · %d agents · %d unread"
                           (if (string-empty-p emacs-agents-board--scope) "All folders" emacs-agents-board--scope)
                           (length sessions) (seq-count #'emacs-agents-unread-p sessions)) width))
      (insert (propertize line 'face 'shadow) "\n"))
    (insert "\n")
    (unless sessions (insert "No agents in this scope.\nUse f to choose a folder or n to create an agent.\n"))
    (dolist (folder folders)
      (dolist (line (emacs-agents-board--wrap (if (string-empty-p folder) "Unfiled" folder) width))
        (insert (propertize line 'face 'emacs-agents-board-heading) "\n"))
      (let ((remaining lanes)
            (members (seq-filter (lambda (s) (equal folder (emacs-agents-session-folder s))) sessions)))
        (while remaining
          (let* ((row (seq-take remaining columns))
                 (groups (mapcar (lambda (lane) (seq-filter (lambda (s) (equal lane (emacs-agents-board--lane s))) members)) row))
                 (stacks (mapcar (lambda (group)
                                   (apply #'append (mapcar (lambda (s) (append (emacs-agents-board--card s cell-width) '(""))) group))) groups)))
            (insert (mapconcat (lambda (pair)
                                 (propertize (emacs-agents-board--pad (format "%s  %d" (car pair) (length (cdr pair))) cell-width)
                                             'face (list 'bold (emacs-agents--activity-face (downcase (car pair))))))
                               (cl-mapcar #'cons row groups) "  ") "\n")
            (dotimes (index (max 1 (apply #'max (mapcar #'length stacks))))
              (cl-loop for stack in stacks for column from 0 do
                       (when (> column 0) (insert "  "))
                       (let* ((line (or (nth index stack) ""))
                              (id (get-text-property 0 'emacs-agents-id line))
                              (start (point)))
                         (insert (emacs-agents-board--pad line cell-width))
                         (when (and id (not (assoc id emacs-agents-board--positions)))
                           (push (list id start (* column (+ cell-width 2)) (line-number-at-pos start))
                                 emacs-agents-board--positions))))
              (insert "\n"))
            (insert "\n")
            (setq remaining (nthcdr (length row) remaining))))))
    (setq emacs-agents-board--positions (nreverse emacs-agents-board--positions))
    (let ((entry (or (assoc emacs-agents-board--selection emacs-agents-board--positions)
                     (car emacs-agents-board--positions))))
      (setq emacs-agents-board--selection (car entry))
      (goto-char (if entry (nth 1 entry) (min old-point (point-max)))))
    (emacs-agents-board--highlight)
    (set-buffer-modified-p nil)))

(defun emacs-agents-board--post-command ()
  "Track explicit cursor selection without acknowledging conversation output."
  (when-let* ((id (get-text-property (point) 'emacs-agents-id)))
    (unless (equal id emacs-agents-board--selection)
      (setq emacs-agents-board--selection id)
      (emacs-agents-board--highlight))))

(defun emacs-agents-board--resize (window)
  "Reflow visible cards when WINDOW changes width."
  (when (and (window-live-p window) (not (= (window-body-width window) (or emacs-agents-board--width 0))))
    (emacs-agents-board--render (window-body-width window))))

(defun emacs-agents-board--refresh ()
  "Refresh a visible board after the shared session cache changes."
  (when-let* ((buffer (get-buffer "*Agent Board*")) (window (get-buffer-window buffer)))
    (with-current-buffer buffer (emacs-agents-board--render (window-body-width window)))))

(defun emacs-agents-board--move (direction)
  "Move selection in DIRECTION using displayed card positions."
  (emacs-agents-board--post-command)
  (let* ((current (assoc emacs-agents-board--selection emacs-agents-board--positions))
         (x (or (nth 2 current) 0)) (y (or (nth 3 current) 0))
         (candidates
          (seq-filter (lambda (entry)
                        (pcase direction
                          ('down (and (= x (nth 2 entry)) (> (nth 3 entry) y)))
                          ('up (and (= x (nth 2 entry)) (< (nth 3 entry) y)))
                          ('left (< (nth 2 entry) x)) ('right (> (nth 2 entry) x))))
                      emacs-agents-board--positions))
         (target (car (sort candidates (lambda (a b)
                                        (< (+ (* 1000 (abs (- y (nth 3 a)))) (abs (- x (nth 2 a))))
                                           (+ (* 1000 (abs (- y (nth 3 b)))) (abs (- x (nth 2 b))))))))))
    (when target
      (setq emacs-agents-board--selection (car target))
      (goto-char (nth 1 target))
      (emacs-agents-board--highlight))))
(defun emacs-agents-board-down () "Select the next card below." (interactive) (emacs-agents-board--move 'down))
(defun emacs-agents-board-up () "Select the next card above." (interactive) (emacs-agents-board--move 'up))
(defun emacs-agents-board-left () "Select a card to the left." (interactive) (emacs-agents-board--move 'left))
(defun emacs-agents-board-right () "Select a card to the right." (interactive) (emacs-agents-board--move 'right))
(defun emacs-agents-board-next ()
  "Select the next card in reading order, wrapping at the end."
  (interactive)
  (let ((target (or (cadr (member (assoc emacs-agents-board--selection emacs-agents-board--positions)
                                 emacs-agents-board--positions))
                    (car emacs-agents-board--positions))))
    (when target (goto-char (nth 1 target)) (emacs-agents-board--post-command))))

(defun emacs-agents-board-scope ()
  "Choose a logical folder, including its descendants, or show all folders."
  (interactive)
  (let* ((choices (cons '("All folders" . "")
                        (mapcar (lambda (f) (cons (concat "Folder: " f) f)) emacs-agents--ui-folders)))
         (choice (completing-read "Board scope: " choices nil t)))
    (setq emacs-agents-board--scope (cdr (assoc choice choices)))
    (emacs-agents-board--render)))

(defun emacs-agents-board-open ()
  "Open the selected card; closing its conversation returns to this board."
  (interactive)
  (let* ((id (or (get-text-property (point) 'emacs-agents-id) (user-error "Select an agent card first")))
         ;; Start before touching the layout, so failure leaves the board intact.
         (buffer (emacs-agents-start id)))
    (setq emacs-agents-board--selection id)
    (set-frame-parameter nil 'emacs-agents-conversation-layout (current-window-configuration))
    (emacs-agents--show-conversation buffer)))

(defun emacs-agents-board-click (event)
  "Open the card at mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (emacs-agents-board-open))

(defun emacs-agents-board-return ()
  "Restore the layout preceding this board, including conversation close state."
  (interactive)
  (let ((layout emacs-agents-board--source-layout)
        (conversation-layout emacs-agents-board--conversation-layout))
    (setq emacs-agents-board--source-layout nil emacs-agents-board--conversation-layout nil)
    (if layout
        (progn (set-window-configuration layout)
               (set-frame-parameter nil 'emacs-agents-conversation-layout conversation-layout))
      (quit-window))))

(defvar emacs-agents-board-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (binding '(("j" . emacs-agents-board-down) ("k" . emacs-agents-board-up)
                       ("h" . emacs-agents-board-left) ("l" . emacs-agents-board-right)
                       ("<down>" . emacs-agents-board-down) ("<up>" . emacs-agents-board-up)
                       ("<left>" . emacs-agents-board-left) ("<right>" . emacs-agents-board-right)
                       ("TAB" . emacs-agents-board-next) ("RET" . emacs-agents-board-open)
                       ("]" . emacs-agents-next-attention) ("[" . emacs-agents-previous-attention)
                       ("<mouse-1>" . emacs-agents-board-click)
                       ("f" . emacs-agents-board-scope) ("g" . emacs-agents-refresh)
                       ("n" . emacs-agents-new) ("i" . emacs-agents-details)
                       ("?" . emacs-agents-actions)
                       ("q" . emacs-agents-board-return)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map))

(define-derived-mode emacs-agents-board-mode special-mode "Agent Board"
  "Cards grouped by folder and observed activity. No manual status changes."
  (setq-local truncate-lines t line-spacing 0.12
              header-line-format " Board · ? actions · [ ] attention · RET open · f folder · q return")
  (buffer-face-set 'fixed-pitch)
  (add-hook 'post-command-hook #'emacs-agents-board--post-command nil t)
  (add-hook 'window-size-change-functions #'emacs-agents-board--resize nil t))

;;;###autoload
(defun emacs-agents-board ()
  "Show the optional board alongside the persistent sidebar."
  (interactive)
  (emacs-agents)
  (emacs-agents--select-main-window)
  (let ((layout (current-window-configuration))
        (conversation-layout (frame-parameter nil 'emacs-agents-conversation-layout))
        (buffer (get-buffer-create "*Agent Board*")))
    (switch-to-buffer buffer)
    (unless (derived-mode-p 'emacs-agents-board-mode) (emacs-agents-board-mode))
    (unless emacs-agents-board--source-layout
      (setq emacs-agents-board--source-layout layout
            emacs-agents-board--conversation-layout conversation-layout))
    (emacs-agents-board--render)))

(provide 'emacs-agents-board)
;;; emacs-agents-board.el ends here
