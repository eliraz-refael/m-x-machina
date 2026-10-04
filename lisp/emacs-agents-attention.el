;;; emacs-agents-attention.el --- Navigate agents needing attention -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Priority navigation selects overview entries, never opens conversations.
;;; Code:
(require 'emacs-agents)
(defvar emacs-agents-board--scope)
(defvar emacs-agents-board--selection)
(declare-function emacs-agents-board--render "emacs-agents-board")

(defun emacs-agents-attention--waiting-p (session)
  "Whether SESSION currently requests input or approval, rather than being idle."
  (member (emacs-agents--activity session) '("waiting" "approval")))

(defun emacs-agents-attention--queue (sessions kind &optional scope)
  "Return attention candidates from SESSIONS in stable creation order.
KIND is `all', `waiting' or `unread'.  For `all', waiting agents precede
unread-only agents.  Exclude archived records and respect folder SCOPE."
  (let* ((eligible (seq-filter
                    (lambda (s)
                      (and (not (emacs-agents-archived-p s))
                           (or (not scope) (string-empty-p scope) (emacs-agents--in-folder-p s scope)))) sessions))
         (waiting (seq-filter #'emacs-agents-attention--waiting-p eligible))
         (unread (seq-filter #'emacs-agents-unread-p eligible)))
    (pcase kind
      ('waiting waiting) ('unread unread)
      (_ (append waiting (seq-remove #'emacs-agents-attention--waiting-p unread))))))

(defun emacs-agents-attention--target (queue current previous)
  "Choose from QUEUE relative to CURRENT, reversing direction for PREVIOUS.
Wrap at either end.  If CURRENT is absent, start at the highest priority item."
  (let* ((ids (mapcar #'emacs-agents-session-id queue))
         (index (cl-position current ids :test #'equal)))
    (when ids
      (nth (if index (mod (+ index (if previous -1 1)) (length ids)) 0) queue))))

(defun emacs-agents-attention--jump (kind previous)
  "Select the next KIND entry, or previous when PREVIOUS is non-nil."
  (let* ((board (derived-mode-p 'emacs-agents-board-mode))
         (dashboard (and (derived-mode-p 'emacs-agents-mode)
                         (not (derived-mode-p 'emacs-agents-archive-mode))))
         (scope (and board emacs-agents-board--scope))
         (current (or (get-text-property (point) 'emacs-agents-id)
                      (and dashboard (tabulated-list-get-id))
                      (and board emacs-agents-board--selection)
                      emacs-agents--managed-id)))
    ;; Refresh observed state before choosing, so resolved requests disappear.
    (emacs-agents-refresh)
    (let* ((queue (emacs-agents-attention--queue emacs-agents--ui-sessions kind scope))
           (target (emacs-agents-attention--target queue current previous)))
      (if (not target)
          (message "No %s agents%s"
                   (pcase kind ('waiting "waiting") ('unread "unread") (_ "waiting or unread"))
                   (if (and scope (not (string-empty-p scope))) " in this board folder; f changes scope" ""))
        (let ((id (emacs-agents-session-id target))
              (folder (emacs-agents-session-folder target)))
          (emacs-agents--reset-read-dwell)
          (cond
           (board
            (setq emacs-agents-board--selection id)
            (emacs-agents-board--render))
           (dashboard
            (goto-char (point-min))
            (while (and (not (eobp)) (not (equal id (tabulated-list-get-id)))) (forward-line 1)))
           (t
            (emacs-agents)
            (setq emacs-agents--collapsed
                  (seq-remove (lambda (closed) (or (equal folder closed)
                                                   (string-prefix-p (concat closed "/") folder)))
                              emacs-agents--collapsed))
            (emacs-agents--render-sidebar emacs-agents--ui-sessions)
            (goto-char (emacs-agents--sidebar-position id))))
          (when (get-buffer-window (current-buffer))
            (set-window-point (get-buffer-window (current-buffer)) (point)))
          (message "Attention %d/%d · %s · %s%s · RET opens conversation"
                   (1+ (cl-position target queue :test #'equal)) (length queue)
                   (emacs-agents-session-name target) (emacs-agents--activity target)
                   (if (emacs-agents-unread-p target) " · unread" ""))
          id)))))

;;;###autoload
(defun emacs-agents-next-attention ()
  "Select the next waiting or unread agent, with waiting agents first."
  (interactive) (emacs-agents-attention--jump 'all nil))
;;;###autoload
(defun emacs-agents-previous-attention ()
  "Select the previous entry in the waiting-first attention queue."
  (interactive) (emacs-agents-attention--jump 'all t))
;;;###autoload
(defun emacs-agents-next-waiting ()
  "Select the next agent requesting input or approval."
  (interactive) (emacs-agents-attention--jump 'waiting nil))
;;;###autoload
(defun emacs-agents-previous-waiting ()
  "Select the previous agent requesting input or approval."
  (interactive) (emacs-agents-attention--jump 'waiting t))
;;;###autoload
(defun emacs-agents-next-unread ()
  "Select the next agent with unseen output."
  (interactive) (emacs-agents-attention--jump 'unread nil))
;;;###autoload
(defun emacs-agents-previous-unread ()
  "Select the previous agent with unseen output."
  (interactive) (emacs-agents-attention--jump 'unread t))

(provide 'emacs-agents-attention)
;;; emacs-agents-attention.el ends here
