;;; mx-machina-board.el --- Folder-scoped agent board -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; A native, optional overview. Cards reflect observed state, never edit it.
;;; Code:
(require 'mx-machina)

(defface mx-machina-board-heading
  '((t :inherit font-lock-keyword-face :weight bold))
  "Folder and lane headings." :group 'mx-machina)
(defface mx-machina-board-border
  '((t :inherit shadow)) "Card borders." :group 'mx-machina)
(defface mx-machina-board-selected
  '((t :inherit highlight)) "Selected board card." :group 'mx-machina)

(defvar-local mx-machina-board--scope "")
(defvar-local mx-machina-board--selection nil)
(defvar-local mx-machina-board--positions nil)
(defvar-local mx-machina-board--width nil)
(defvar-local mx-machina-board--source-layout nil)
(defvar-local mx-machina-board--conversation-layout nil)
(defvar-local mx-machina-board--overlays nil)
(defconst mx-machina-board--lanes '("Working" "Waiting" "Ready" "Stopped"))

(defun mx-machina-board--lane (session)
  "Return SESSION's observed lane, including states outside the main four."
  (pcase (mx-machina--activity session)
    ("working" "Working") ((or "waiting" "approval") "Waiting")
    ("ready" "Ready") ((or "stopped" "error") "Stopped") (_ "Other")))

(defun mx-machina-board--wrap (text width)
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

(defun mx-machina-board--pad (text width)
  "Pad TEXT with spaces to WIDTH display columns."
  (concat text (make-string (max 0 (- width (string-width text))) ?\s)))

(defun mx-machina-board--card (session width)
  "Return rendered card lines for SESSION within WIDTH columns."
  (let* ((id (mx-machina-session-id session))
         (state (mx-machina--activity session))
         (inside (- width 4))
         (title (mapcar (lambda (s) (propertize s 'face 'bold))
                        (mx-machina-board--wrap (mx-machina-session-name session) inside)))
         (status (concat (propertize (upcase state) 'face (mx-machina--activity-face state))
                         (when (mx-machina-unread-p session)
                           (propertize " · NEW" 'face 'mx-machina-unread))))
         (branch (truncate-string-to-width (mx-machina-session-branch session) inside nil nil "…"))
         (lines (append
                 (list (propertize (concat "┌" (make-string (- width 2) ?─) "┐") 'face 'mx-machina-board-border))
                 (mapcar (lambda (line) (concat "│ " (mx-machina-board--pad line inside) " │"))
                         (append title (list status (propertize branch 'face 'shadow))))
                 (list (propertize (concat "└" (make-string (- width 2) ?─) "┘") 'face 'mx-machina-board-border)))))
    (mapcar (lambda (line)
              (propertize line 'mx-machina-id id 'mouse-face 'highlight
                          'help-echo (format "%s\n%s · %s\n%s\nRET or click to open"
                                             (mx-machina-session-name session)
                                             (mx-machina-session-profile session) state
                                             (mx-machina-session-directory session))
                          'rear-nonsticky t)) lines)))

(defun mx-machina-board--highlight ()
  "Highlight all visible fragments of the selected card."
  (mapc #'delete-overlay mx-machina-board--overlays)
  (setq mx-machina-board--overlays nil)
  (let ((position (point-min)))
    (while (< position (point-max))
      (let ((end (next-single-property-change position 'mx-machina-id nil (point-max))))
        (when (and mx-machina-board--selection
                   (equal mx-machina-board--selection (get-text-property position 'mx-machina-id)))
          (let ((overlay (make-overlay position end)))
            (overlay-put overlay 'face 'mx-machina-board-selected)
            (push overlay mx-machina-board--overlays)))
        (setq position end)))))

(defun mx-machina-board--render (&optional width)
  "Render cached sessions at WIDTH, preserving selected agent identity."
  (setq width (max 20 (or width (window-body-width (get-buffer-window (current-buffer))) 80)))
  (let* ((sessions (seq-filter
                    (lambda (s) (and (not (mx-machina-archived-p s))
                                     (or (string-empty-p mx-machina-board--scope)
                                         (mx-machina--in-folder-p s mx-machina-board--scope))))
                    mx-machina--ui-sessions))
         (folders (sort (delete-dups (mapcar #'mx-machina-session-folder sessions)) #'string-lessp))
         (lanes (append mx-machina-board--lanes
                        (when (seq-some (lambda (s) (equal (mx-machina-board--lane s) "Other")) sessions)
                          '("Other"))))
         (columns (max 1 (min 4 (/ (+ width 2) 26))))
         (cell-width (/ (- width (* 2 (1- columns))) columns))
         (old-point (point))
         (inhibit-read-only t))
    (setq mx-machina-board--width width mx-machina-board--positions nil)
    (erase-buffer)
    (insert (propertize "M-X MACHINA\n" 'face 'mx-machina-board-heading))
    (dolist (line (mx-machina-board--wrap
                   (format "%s · %d agents · %d unread"
                           (if (string-empty-p mx-machina-board--scope) "All folders" mx-machina-board--scope)
                           (length sessions) (seq-count #'mx-machina-unread-p sessions)) width))
      (insert (propertize line 'face 'shadow) "\n"))
    (insert "\n")
    (unless sessions (insert "No agents in this scope.\nUse f to choose a folder or n to create an agent.\n"))
    (dolist (folder folders)
      (dolist (line (mx-machina-board--wrap (if (string-empty-p folder) "Unfiled" folder) width))
        (insert (propertize line 'face 'mx-machina-board-heading) "\n"))
      (let ((remaining lanes)
            (members (seq-filter (lambda (s) (equal folder (mx-machina-session-folder s))) sessions)))
        (while remaining
          (let* ((row (seq-take remaining columns))
                 (groups (mapcar (lambda (lane) (seq-filter (lambda (s) (equal lane (mx-machina-board--lane s))) members)) row))
                 (stacks (mapcar (lambda (group)
                                   (apply #'append (mapcar (lambda (s) (append (mx-machina-board--card s cell-width) '(""))) group))) groups)))
            (insert (mapconcat (lambda (pair)
                                 (propertize (mx-machina-board--pad (format "%s  %d" (car pair) (length (cdr pair))) cell-width)
                                             'face (list 'bold (mx-machina--activity-face (downcase (car pair))))))
                               (cl-mapcar #'cons row groups) "  ") "\n")
            (dotimes (index (max 1 (apply #'max (mapcar #'length stacks))))
              (cl-loop for stack in stacks for column from 0 do
                       (when (> column 0) (insert "  "))
                       (let* ((line (or (nth index stack) ""))
                              (id (get-text-property 0 'mx-machina-id line))
                              (start (point)))
                         (insert (mx-machina-board--pad line cell-width))
                         (when (and id (not (assoc id mx-machina-board--positions)))
                           (push (list id start (* column (+ cell-width 2)) (line-number-at-pos start))
                                 mx-machina-board--positions))))
              (insert "\n"))
            (insert "\n")
            (setq remaining (nthcdr (length row) remaining))))))
    (setq mx-machina-board--positions (nreverse mx-machina-board--positions))
    (let ((entry (or (assoc mx-machina-board--selection mx-machina-board--positions)
                     (car mx-machina-board--positions))))
      (setq mx-machina-board--selection (car entry))
      (goto-char (if entry (nth 1 entry) (min old-point (point-max)))))
    (mx-machina-board--highlight)
    (set-buffer-modified-p nil)))

(defun mx-machina-board--post-command ()
  "Track explicit cursor selection without acknowledging conversation output."
  (when-let* ((id (get-text-property (point) 'mx-machina-id)))
    (unless (equal id mx-machina-board--selection)
      (setq mx-machina-board--selection id)
      (mx-machina-board--highlight))))

(defun mx-machina-board--resize (window)
  "Reflow visible cards when WINDOW changes width."
  (when (and (window-live-p window) (not (= (window-body-width window) (or mx-machina-board--width 0))))
    (mx-machina-board--render (window-body-width window))))

(defun mx-machina-board--refresh ()
  "Refresh a visible board after the shared session cache changes."
  (when-let* ((buffer (get-buffer "*M-x Machina Board*")) (window (get-buffer-window buffer)))
    (with-current-buffer buffer (mx-machina-board--render (window-body-width window)))))

(defun mx-machina-board--move (direction)
  "Move selection in DIRECTION using displayed card positions."
  (mx-machina-board--post-command)
  (let* ((current (assoc mx-machina-board--selection mx-machina-board--positions))
         (x (or (nth 2 current) 0)) (y (or (nth 3 current) 0))
         (candidates
          (seq-filter (lambda (entry)
                        (pcase direction
                          ('down (and (= x (nth 2 entry)) (> (nth 3 entry) y)))
                          ('up (and (= x (nth 2 entry)) (< (nth 3 entry) y)))
                          ('left (< (nth 2 entry) x)) ('right (> (nth 2 entry) x))))
                      mx-machina-board--positions))
         (target (car (sort candidates (lambda (a b)
                                        (< (+ (* 1000 (abs (- y (nth 3 a)))) (abs (- x (nth 2 a))))
                                           (+ (* 1000 (abs (- y (nth 3 b)))) (abs (- x (nth 2 b))))))))))
    (when target
      (setq mx-machina-board--selection (car target))
      (goto-char (nth 1 target))
      (mx-machina-board--highlight))))
(defun mx-machina-board-down () "Select the next card below." (interactive) (mx-machina-board--move 'down))
(defun mx-machina-board-up () "Select the next card above." (interactive) (mx-machina-board--move 'up))
(defun mx-machina-board-left () "Select a card to the left." (interactive) (mx-machina-board--move 'left))
(defun mx-machina-board-right () "Select a card to the right." (interactive) (mx-machina-board--move 'right))
(defun mx-machina-board-next ()
  "Select the next card in reading order, wrapping at the end."
  (interactive)
  (let ((target (or (cadr (member (assoc mx-machina-board--selection mx-machina-board--positions)
                                 mx-machina-board--positions))
                    (car mx-machina-board--positions))))
    (when target (goto-char (nth 1 target)) (mx-machina-board--post-command))))

(defun mx-machina-board-scope ()
  "Choose a logical folder, including its descendants, or show all folders."
  (interactive)
  (let* ((choices (cons '("All folders" . "")
                        (mapcar (lambda (f) (cons (concat "Folder: " f) f)) mx-machina--ui-folders)))
         (choice (completing-read "Board scope: " choices nil t)))
    (setq mx-machina-board--scope (cdr (assoc choice choices)))
    (mx-machina-board--render)))

(defun mx-machina-board-open ()
  "Open the selected card; closing its conversation returns to this board."
  (interactive)
  (let* ((id (or (get-text-property (point) 'mx-machina-id) (user-error "Select an agent card first")))
         ;; Start before touching the layout, so failure leaves the board intact.
         (buffer (mx-machina-start id)))
    (setq mx-machina-board--selection id)
    (set-frame-parameter nil 'mx-machina-conversation-layout (current-window-configuration))
    (mx-machina--show-conversation buffer)))

(defun mx-machina-board-click (event)
  "Open the card at mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (mx-machina-board-open))

(defun mx-machina-board-return ()
  "Restore the layout preceding this board, including conversation close state."
  (interactive)
  (let ((layout mx-machina-board--source-layout)
        (conversation-layout mx-machina-board--conversation-layout))
    (setq mx-machina-board--source-layout nil mx-machina-board--conversation-layout nil)
    (if layout
        (progn (set-window-configuration layout)
               (set-frame-parameter nil 'mx-machina-conversation-layout conversation-layout))
      (quit-window))))

(defvar mx-machina-board-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (binding '(("j" . mx-machina-board-down) ("k" . mx-machina-board-up)
                       ("h" . mx-machina-board-left) ("l" . mx-machina-board-right)
                       ("<down>" . mx-machina-board-down) ("<up>" . mx-machina-board-up)
                       ("<left>" . mx-machina-board-left) ("<right>" . mx-machina-board-right)
                       ("TAB" . mx-machina-board-next) ("RET" . mx-machina-board-open)
                       ("]" . mx-machina-next-attention) ("[" . mx-machina-previous-attention)
                       ("<mouse-1>" . mx-machina-board-click)
                       ("f" . mx-machina-board-scope) ("g" . mx-machina-refresh)
                       ("n" . mx-machina-new) ("i" . mx-machina-details)
                       ("?" . mx-machina-actions)
                       ("q" . mx-machina-board-return)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map))

(define-derived-mode mx-machina-board-mode special-mode "Machina Board"
  "Cards grouped by folder and observed activity. No manual status changes."
  (setq-local truncate-lines t line-spacing 0.12
              header-line-format " Board · ? actions · [ ] attention · RET open · f folder · q return")
  (buffer-face-set 'fixed-pitch)
  (add-hook 'post-command-hook #'mx-machina-board--post-command nil t)
  (add-hook 'window-size-change-functions #'mx-machina-board--resize nil t))

;;;###autoload
(defun mx-machina-board ()
  "Show the optional board alongside the persistent sidebar."
  (interactive)
  (mx-machina)
  (mx-machina--select-main-window)
  (let ((layout (current-window-configuration))
        (conversation-layout (frame-parameter nil 'mx-machina-conversation-layout))
        (buffer (get-buffer-create "*M-x Machina Board*")))
    (switch-to-buffer buffer)
    (unless (derived-mode-p 'mx-machina-board-mode) (mx-machina-board-mode))
    (unless mx-machina-board--source-layout
      (setq mx-machina-board--source-layout layout
            mx-machina-board--conversation-layout conversation-layout))
    (mx-machina-board--render)))

(provide 'mx-machina-board)
;;; mx-machina-board.el ends here
