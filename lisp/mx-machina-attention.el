;;; mx-machina-attention.el --- Navigate agents needing attention -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Priority navigation selects overview entries, never opens conversations.
;;; Code:
(require 'mx-machina)
(defvar mx-machina-board--scope)
(defvar mx-machina-board--selection)
(declare-function mx-machina-board--render "mx-machina-board")

(defun mx-machina-attention--waiting-p (session)
  "Whether SESSION currently requests input or approval, rather than being idle."
  (member (mx-machina--activity session) '("waiting" "approval")))

(defun mx-machina-attention--queue (sessions kind &optional scope)
  "Return attention candidates from SESSIONS in stable creation order.
KIND is `all', `waiting' or `unread'.  For `all', waiting agents precede
unread-only agents.  Exclude archived records and respect folder SCOPE."
  (let* ((eligible (seq-filter
                    (lambda (s)
                      (and (not (mx-machina-archived-p s))
                           (or (not scope) (string-empty-p scope) (mx-machina--in-folder-p s scope)))) sessions))
         (waiting (seq-filter #'mx-machina-attention--waiting-p eligible))
         (unread (seq-filter #'mx-machina-unread-p eligible)))
    (pcase kind
      ('waiting waiting) ('unread unread)
      (_ (append waiting (seq-remove #'mx-machina-attention--waiting-p unread))))))

(defun mx-machina-attention--target (queue current previous)
  "Choose from QUEUE relative to CURRENT, reversing direction for PREVIOUS.
Wrap at either end.  If CURRENT is absent, start at the highest priority item."
  (let* ((ids (mapcar #'mx-machina-session-id queue))
         (index (cl-position current ids :test #'equal)))
    (when ids
      (nth (if index (mod (+ index (if previous -1 1)) (length ids)) 0) queue))))

(defun mx-machina-attention--jump (kind previous)
  "Select the next KIND entry, or previous when PREVIOUS is non-nil."
  (let* ((board (derived-mode-p 'mx-machina-board-mode))
         (dashboard (and (derived-mode-p 'mx-machina-mode)
                         (not (derived-mode-p 'mx-machina-archive-mode))))
         (scope (and board mx-machina-board--scope))
         (current (or (get-text-property (point) 'mx-machina-id)
                      (and dashboard (tabulated-list-get-id))
                      (and board mx-machina-board--selection)
                      mx-machina--managed-id)))
    ;; Refresh observed state before choosing, so resolved requests disappear.
    (mx-machina-refresh)
    (let* ((queue (mx-machina-attention--queue mx-machina--ui-sessions kind scope))
           (target (mx-machina-attention--target queue current previous)))
      (if (not target)
          (message "No %s agents%s"
                   (pcase kind ('waiting "waiting") ('unread "unread") (_ "waiting or unread"))
                   (if (and scope (not (string-empty-p scope))) " in this board folder; f changes scope" ""))
        (let ((id (mx-machina-session-id target))
              (folder (mx-machina-session-folder target)))
          (mx-machina--reset-read-dwell)
          (cond
           (board
            (setq mx-machina-board--selection id)
            (mx-machina-board--render))
           (dashboard
            (goto-char (point-min))
            (while (and (not (eobp)) (not (equal id (tabulated-list-get-id)))) (forward-line 1)))
           (t
            (mx-machina)
            (setq mx-machina--collapsed
                  (seq-remove (lambda (closed) (or (equal folder closed)
                                                   (string-prefix-p (concat closed "/") folder)))
                              mx-machina--collapsed))
            (mx-machina--render-sidebar mx-machina--ui-sessions)
            (goto-char (mx-machina--sidebar-position id))))
          (when (get-buffer-window (current-buffer))
            (set-window-point (get-buffer-window (current-buffer)) (point)))
          (message "Attention %d/%d · %s · %s%s · RET opens conversation"
                   (1+ (cl-position target queue :test #'equal)) (length queue)
                   (mx-machina-session-name target) (mx-machina--activity target)
                   (if (mx-machina-unread-p target) " · unread" ""))
          id)))))

;;;###autoload
(defun mx-machina-next-attention ()
  "Select the next waiting or unread agent, with waiting agents first."
  (interactive) (mx-machina-attention--jump 'all nil))
;;;###autoload
(defun mx-machina-previous-attention ()
  "Select the previous entry in the waiting-first attention queue."
  (interactive) (mx-machina-attention--jump 'all t))
;;;###autoload
(defun mx-machina-next-waiting ()
  "Select the next agent requesting input or approval."
  (interactive) (mx-machina-attention--jump 'waiting nil))
;;;###autoload
(defun mx-machina-previous-waiting ()
  "Select the previous agent requesting input or approval."
  (interactive) (mx-machina-attention--jump 'waiting t))
;;;###autoload
(defun mx-machina-next-unread ()
  "Select the next agent with unseen output."
  (interactive) (mx-machina-attention--jump 'unread nil))
;;;###autoload
(defun mx-machina-previous-unread ()
  "Select the previous agent with unseen output."
  (interactive) (mx-machina-attention--jump 'unread t))

(provide 'mx-machina-attention)
;;; mx-machina-attention.el ends here
