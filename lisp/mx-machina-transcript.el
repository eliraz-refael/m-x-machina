;;; mx-machina-transcript.el --- Read and copy saved Claude conversations -*- lexical-binding: t; -*-

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
;; A snapshot of user/assistant text from the current session's saved JSONL.
;; Unlike a live terminal screen this buffer stays still during text selection.
;;; Code:
(require 'mx-machina)
(require 'mx-machina-transport)
(require 'json)
(require 'map)
(require 'seq)
(defvar mx-machina-eat-profiles)
(declare-function mx-machina-backend-configs "mx-machina-backend")
(defvar mx-machina--managed-id)
(declare-function mx-machina--read-id "mx-machina")
(declare-function mx-machina--select-main-window "mx-machina-ui")
(declare-function mx-machina--update-active-session "mx-machina-ui")
(defvar-local mx-machina-transcript--source nil)
(defvar-local mx-machina-transcript--stale nil)
(defvar mx-machina-transcript--buffers nil)
(defvar mx-machina--running)

(defun mx-machina-transcript--forget ()
  "Release this snapshot's message observer when the last snapshot goes away."
  (setq mx-machina-transcript--buffers (delq (current-buffer) mx-machina-transcript--buffers))
  (unless mx-machina-transcript--buffers
    (remove-hook 'mx-machina-backend-event-hook #'mx-machina-transcript--notice)))

(defun mx-machina-transcript--notice (transport kind _data)
  "Mark snapshots stale when event KIND is a message from current TRANSPORT."
  (when (eq kind 'message)
    (maphash
     (lambda (id entry)
       (when (eq transport (cdr entry))
         (dolist (buffer mx-machina-transcript--buffers)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (when (equal id mx-machina--managed-id)
                 (setq mx-machina-transcript--stale t)
                 (force-mode-line-update)))))))
     mx-machina--running)))

(defun mx-machina-transcript--header (session)
  "Set SESSION's snapshot header, including its freshness indicator."
  (setq header-line-format
        (list (format " %s · Saved transcript · " (mx-machina-session-name session))
              '(:eval (if mx-machina-transcript--stale
                          (propertize "stale — g to refresh" 'face 'warning)
                        "g refresh")) " · q return")))

(defun mx-machina-transcript--file (session)
  "Find SESSION's saved Claude transcript within its configured account."
  (let* ((config (seq-find (lambda (c) (equal (symbol-name (map-elt c :identifier))
                                            (mx-machina-session-profile session)))
                          (mx-machina-backend-configs)))
         (env (seq-find (lambda (value) (string-prefix-p "CLAUDE_CONFIG_DIR=" value))
                         (map-elt config :environment)))
         (root (expand-file-name "projects/" (expand-file-name
                                              (if env (substring env (length "CLAUDE_CONFIG_DIR="))
                                                (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude")))))
         (sid (mx-machina-session-conversation session)))
    (unless (memq (map-elt config :interface) '(eat vterm))
      (user-error "Use the agent-shell conversation directly; saved snapshots support Claude terminal profiles"))
    (unless (and sid (string-match-p "\\`[[:alnum:]-]+\\'" sid))
      (user-error "This agent has no saved Claude conversation ID"))
    (or (and (file-directory-p root)
             (seq-some (lambda (project)
                         (let ((file (expand-file-name (concat sid ".jsonl") project)))
                           (when (and (file-directory-p project) (file-readable-p file)) file)))
                       (directory-files root t directory-files-no-dot-files-regexp)))
        (user-error "Claude has not saved a transcript for this conversation yet"))))

(defun mx-machina-transcript--text (file)
  "Return FILE's complete user and assistant text, ignoring partial last writes."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (messages (seen (make-hash-table :test #'equal)))
      (while (search-forward "\n" nil t)
        (let* ((row (json-parse-string (buffer-substring-no-properties (point-min) (1- (point)))
                                       :object-type 'alist :array-type 'list :null-object nil :false-object nil))
               (role (alist-get 'type row))
               (uuid (alist-get 'uuid row))
               (content (alist-get 'content (alist-get 'message row)))
               (text (if (stringp content) content
                       (mapconcat (lambda (part) (or (alist-get 'text part) ""))
                                  (seq-filter (lambda (part) (equal (alist-get 'type part) "text")) content) "\n"))))
          (when (and (member role '("user" "assistant"))
                     (not (alist-get 'isMeta row))
                     (not (and (equal role "user")
                               (string-match-p
                                (concat "\\`[[:space:]]*<"
                                        (regexp-opt '("task-notification" "command-name" "command-message"
                                                      "bash-input" "bash-stdout" "local-command-stdout" "bash-stderr"))
                                        "\\(?:[[:space:]>]\\)") text)))
                     (not (and uuid (gethash uuid seen)))
                     (not (string-empty-p text)))
            (when uuid (puthash uuid t seen))
            (push (concat (if (equal role "user") "You" "Claude") "\n\n" text "\n\n") messages)))
        (delete-region (point-min) (point)))
      (apply #'concat (nreverse messages)))))

(defun mx-machina-transcript-refresh ()
  "Refresh the snapshot explicitly, retaining the reader's position."
  (interactive)
  (unless mx-machina--managed-id (user-error "Agent record deleted; this snapshot is retained for reading"))
  (let* ((session (mx-machina-session mx-machina--managed-id))
         (text (mx-machina-transcript--text (mx-machina-transcript--file session)))
         (position (point))
         (inhibit-read-only t))
    (erase-buffer)
    (insert text)
    (goto-char (min position (point-max)))
    (setq mx-machina-transcript--stale nil)
    (mx-machina-transcript--header session)))

(defun mx-machina-transcript-return ()
  "Return to the original terminal without restarting anything."
  (interactive)
  (if (buffer-live-p mx-machina-transcript--source)
      (switch-to-buffer mx-machina-transcript--source)
    (quit-window))
  (mx-machina--update-active-session))

(defvar mx-machina-transcript-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'mx-machina-transcript-refresh)
    (define-key map (kbd "q") #'mx-machina-transcript-return)
    (define-key map (kbd "C-c C-t") #'mx-machina-transcript-return)
    map))

(define-derived-mode mx-machina-transcript-mode special-mode "Machina Transcript"
  "Read-only snapshot for searching, selecting and copying agent messages."
  (setq-local truncate-lines nil)
  ;; A static snapshot cannot confirm that newly arriving output was seen.
  (setq-local mx-machina--read-position-function (lambda () nil))
  (cl-pushnew (current-buffer) mx-machina-transcript--buffers)
  (add-hook 'mx-machina-backend-event-hook #'mx-machina-transcript--notice)
  (add-hook 'kill-buffer-hook #'mx-machina-transcript--forget nil t)
  (add-hook 'change-major-mode-hook #'mx-machina-transcript--forget nil t)
  (visual-line-mode 1))

;;;###autoload
(defun mx-machina-transcript ()
  "Open this Claude agent's saved conversation as ordinary selectable text."
  (interactive)
  (let* ((id (mx-machina--read-id))
         (source (current-buffer))
         (session (mx-machina-session id))
         (file (mx-machina-transcript--file session))
         (text (mx-machina-transcript--text file))
         (buffer (get-buffer-create (format "*Agent transcript %s*" (substring id 0 8)))))
    (with-current-buffer buffer
      (mx-machina-transcript-mode)
      (setq-local mx-machina--managed-id id mx-machina-transcript--source source)
      (let ((inhibit-read-only t)) (erase-buffer) (insert text))
      (goto-char (point-min))
      (mx-machina-transcript--header session))
    (mx-machina--select-main-window)
    (switch-to-buffer buffer)
    (mx-machina--update-active-session)))

(provide 'mx-machina-transcript)
;;; mx-machina-transcript.el ends here
