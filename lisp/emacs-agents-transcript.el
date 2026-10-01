;;; emacs-agents-transcript.el --- Read and copy saved Claude conversations -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; A snapshot of user/assistant text from the current session's saved JSONL.
;; Unlike a live terminal screen this buffer stays still during text selection.
;;; Code:
(require 'emacs-agents-store)
(require 'emacs-agents-transport)
(require 'json)
(require 'map)
(require 'seq)
(defvar emacs-agents-eat-profiles)
(declare-function emacs-agents-backend-configs "emacs-agents-backend")
(defvar emacs-agents--managed-id)
(declare-function emacs-agents--read-id "emacs-agents")
(declare-function emacs-agents--select-main-window "emacs-agents-ui")
(declare-function emacs-agents--update-active-session "emacs-agents-ui")
(defvar-local emacs-agents-transcript--source nil)
(defvar-local emacs-agents-transcript--stale nil)
(defvar emacs-agents-transcript--buffers nil)
(defvar emacs-agents--running)

(defun emacs-agents-transcript--forget ()
  "Release this snapshot's message observer when the last snapshot goes away."
  (setq emacs-agents-transcript--buffers (delq (current-buffer) emacs-agents-transcript--buffers))
  (unless emacs-agents-transcript--buffers
    (remove-hook 'emacs-agents-backend-event-hook #'emacs-agents-transcript--notice)))

(defun emacs-agents-transcript--notice (transport kind _data)
  "Mark snapshots stale on new messages from their current TRANSPORT."
  (when (eq kind 'message)
    (maphash
     (lambda (id entry)
       (when (eq transport (cdr entry))
         (dolist (buffer emacs-agents-transcript--buffers)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (when (equal id emacs-agents--managed-id)
                 (setq emacs-agents-transcript--stale t)
                 (force-mode-line-update)))))))
     emacs-agents--running)))

(defun emacs-agents-transcript--header (session)
  "Set SESSION's snapshot header, including its freshness indicator."
  (setq header-line-format
        (list (format " %s · Saved transcript · " (emacs-agents-session-name session))
              '(:eval (if emacs-agents-transcript--stale
                          (propertize "stale — g to refresh" 'face 'warning)
                        "g refresh")) " · q return")))

(defun emacs-agents-transcript--file (session)
  "Find SESSION's saved Claude transcript within its configured account."
  (let* ((config (seq-find (lambda (c) (equal (symbol-name (map-elt c :identifier))
                                            (emacs-agents-session-profile session)))
                          (emacs-agents-backend-configs)))
         (env (seq-find (lambda (value) (string-prefix-p "CLAUDE_CONFIG_DIR=" value))
                         (map-elt config :environment)))
         (root (expand-file-name "projects/" (expand-file-name
                                              (if env (substring env (length "CLAUDE_CONFIG_DIR="))
                                                (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude")))))
         (sid (emacs-agents-session-conversation session)))
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

(defun emacs-agents-transcript--text (file)
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

(defun emacs-agents-transcript-refresh ()
  "Refresh the snapshot explicitly, retaining the reader's position."
  (interactive)
  (unless emacs-agents--managed-id (user-error "Agent record deleted; this snapshot is retained for reading"))
  (let* ((session (emacs-agents-session emacs-agents--managed-id))
         (text (emacs-agents-transcript--text (emacs-agents-transcript--file session)))
         (position (point))
         (inhibit-read-only t))
    (erase-buffer)
    (insert text)
    (goto-char (min position (point-max)))
    (setq emacs-agents-transcript--stale nil)
    (emacs-agents-transcript--header session)))

(defun emacs-agents-transcript-return ()
  "Return to the original terminal without restarting anything."
  (interactive)
  (if (buffer-live-p emacs-agents-transcript--source)
      (switch-to-buffer emacs-agents-transcript--source)
    (quit-window))
  (emacs-agents--update-active-session))

(defvar emacs-agents-transcript-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'emacs-agents-transcript-refresh)
    (define-key map (kbd "q") #'emacs-agents-transcript-return)
    (define-key map (kbd "C-c C-t") #'emacs-agents-transcript-return)
    map))

(define-derived-mode emacs-agents-transcript-mode special-mode "Agent Transcript"
  "Read-only snapshot for searching, selecting and copying agent messages."
  (setq-local truncate-lines nil)
  ;; A static snapshot cannot confirm that newly arriving output was seen.
  (setq-local emacs-agents--read-position-function (lambda () nil))
  (cl-pushnew (current-buffer) emacs-agents-transcript--buffers)
  (add-hook 'emacs-agents-backend-event-hook #'emacs-agents-transcript--notice)
  (add-hook 'kill-buffer-hook #'emacs-agents-transcript--forget nil t)
  (add-hook 'change-major-mode-hook #'emacs-agents-transcript--forget nil t)
  (visual-line-mode 1))

(defun emacs-agents-transcript ()
  "Open this Claude agent's saved conversation as ordinary selectable text."
  (interactive)
  (let* ((id (emacs-agents--read-id))
         (source (current-buffer))
         (session (emacs-agents-session id))
         (file (emacs-agents-transcript--file session))
         (text (emacs-agents-transcript--text file))
         (buffer (get-buffer-create (format "*Agent transcript %s*" (substring id 0 8)))))
    (with-current-buffer buffer
      (emacs-agents-transcript-mode)
      (setq-local emacs-agents--managed-id id emacs-agents-transcript--source source)
      (let ((inhibit-read-only t)) (erase-buffer) (insert text))
      (goto-char (point-min))
      (emacs-agents-transcript--header session))
    (emacs-agents--select-main-window)
    (switch-to-buffer buffer)
    (emacs-agents--update-active-session)))

(provide 'emacs-agents-transcript)
;;; emacs-agents-transcript.el ends here
