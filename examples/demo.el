;;; demo.el --- Offline interactive demo -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Load this file, then M-x mx-machina-demo.  Requires agent-shell and Python 3.
(add-to-list 'load-path
             (expand-file-name "../lisp" (file-name-directory (or load-file-name buffer-file-name))))
(require 'mx-machina)
(require 'agent-shell)
(require 'agent-shell-mock-agent)

(defvar emacs-agents-demo--script
  (expand-file-name "../test/fake-acp.py" (file-name-directory (or load-file-name buffer-file-name))))

(defun emacs-agents-demo-profile ()
  "Return an offline profile without changing other mock-agent configuration."
  (let* ((command (list "python3" emacs-agents-demo--script
                        (expand-file-name "demo/backend" emacs-agents-directory)))
         (config (agent-shell-mock-agent-make-agent-config)))
    (setf (alist-get :identifier config) 'emacs-agents-demo
          (alist-get :buffer-name config) "Agents Demo"
          (alist-get :mode-line-name config) "Offline Demo"
          (alist-get :client-maker config)
          (lambda (buffer)
            (let ((agent-shell-mock-agent-acp-command command))
              (agent-shell-mock-agent-make-client :buffer buffer))))
    config))

(defun mx-machina-demo ()
  "Open an offline session that can be stopped and resumed across Emacs restarts."
  (interactive)
  (unless (executable-find "python3") (user-error "The demo requires Python 3"))
  (let* ((repo (expand-file-name "demo/worktree/" emacs-agents-directory))
         (saved (seq-find (lambda (s) (equal (emacs-agents-session-profile s) "emacs-agents-demo"))
                          (emacs-agents-sessions))))
    (unless (file-directory-p (expand-file-name ".git" repo))
      (make-directory repo t)
      (emacs-agents--git repo "init" "-b" "main")
      (emacs-agents--git repo "-c" "user.name=Offline Demo" "-c" "user.email=demo@example.invalid"
                         "-c" "commit.gpgsign=false" "commit" "--allow-empty" "-m" "Offline demo"))
    (let ((id (if saved (emacs-agents-session-id saved)
                (emacs-agents-create "Offline demo" repo "emacs-agents-demo"))))
      (mx-machina)
      (emacs-agents-open id))))

;; Resolve any user-supplied config function, preserving its existing profiles.
(setq agent-shell-agent-configs
      (cons #'emacs-agents-demo-profile
            (remq #'emacs-agents-demo-profile
                  (if (functionp agent-shell-agent-configs)
                      (funcall agent-shell-agent-configs)
                    agent-shell-agent-configs))))
(defalias 'emacs-agents-demo #'mx-machina-demo)
;;; demo.el ends here
