;;; doom.el --- Optional Doom and Evil setup -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Load this file; it resolves the package location relative to itself.
(add-to-list 'load-path
             (expand-file-name "../lisp" (file-name-directory (or load-file-name buffer-file-name))))
(require 'emacs-agents)

(with-eval-after-load 'evil
  (evil-set-initial-state 'emacs-agents-board-mode 'motion)
  (with-eval-after-load 'emacs-agents-board
    (dolist (key '("j" "k" "h" "l" "TAB" "RET" "f" "g" "n" "i" "q"))
      (evil-define-key 'motion emacs-agents-board-mode-map (kbd key)
        (lookup-key emacs-agents-board-mode-map (kbd key)))))
  (add-hook 'emacs-agents-eat-setup-hook #'emacs-agents-eat-setup-evil)
  (add-hook 'emacs-agents-vterm-setup-hook #'emacs-agents-vterm-setup-evil)
  (evil-set-initial-state 'emacs-agents-diagnostics-mode 'normal)
  (with-eval-after-load 'emacs-agents-diagnostics
    (evil-define-key 'normal emacs-agents-diagnostics-mode-map
      (kbd "q") #'emacs-agents-diagnostics-return
      (kbd "g") #'emacs-agents-diagnostics-refresh
      (kbd "W") #'emacs-agents-rebind-worktree
      (kbd "R") #'emacs-agents-retry
      (kbd "w") #'emacs-agents-diagnostics-copy))
  (evil-set-initial-state 'emacs-agents-transcript-mode 'normal)
  (with-eval-after-load 'emacs-agents-transcript
    (evil-define-key 'normal emacs-agents-transcript-mode-map
      (kbd "q") #'emacs-agents-transcript-return
      (kbd "g") #'emacs-agents-transcript-refresh))
  (evil-define-key 'normal emacs-agents-conversation-mode-map
    (kbd "q") #'emacs-agents-close-view)
  (evil-set-initial-state 'emacs-agents-sidebar-mode 'motion)
  (evil-set-initial-state 'emacs-agents-archive-mode 'motion)
  (evil-define-key 'motion emacs-agents-archive-mode-map
    (kbd "RET") #'emacs-agents-restore
    (kbd "r") #'emacs-agents-restore
    (kbd "A") #'emacs-agents-dashboard
    (kbd "d") #'emacs-agents-delete)
  (dolist (binding '(("j" . emacs-agents-sidebar-next) ("k" . emacs-agents-sidebar-previous)
                     ("n" . emacs-agents-new) ("RET" . emacs-agents-sidebar-open)
                     ("N" . emacs-agents-new-folder) ("M" . emacs-agents-move)
                     ("R" . emacs-agents-rename) ("u" . emacs-agents-mark-read)
                     ("r" . emacs-agents-open) ("x" . emacs-agents-stop)
                     ("a" . emacs-agents-archive) ("A" . emacs-agents-archived)
                     ("d" . emacs-agents-delete)
                     ("g" . emacs-agents-refresh) ("f" . emacs-agents-files)
                     ("m" . emacs-agents-magit) ("i" . emacs-agents-details)
                     ("W" . emacs-agents-rebind-worktree)
                     ("B" . emacs-agents-board)
                     ("e" . emacs-agents-eshell)
                     ("TAB" . emacs-agents-sidebar-expand) ("z" . emacs-agents-focus)
                     ("D" . emacs-agents-dashboard) ("c" . emacs-agents-close-view)
                     ("q" . quit-window)))
    (evil-define-key 'motion emacs-agents-sidebar-mode-map (kbd (car binding)) (cdr binding)))
  (evil-set-initial-state 'emacs-agents-mode 'motion)
  (dolist (binding '(("j" . next-line) ("k" . previous-line)
                     ("n" . emacs-agents-new) ("RET" . emacs-agents-open)
                     ("r" . emacs-agents-open) ("x" . emacs-agents-stop)
                     ("a" . emacs-agents-archive) ("A" . emacs-agents-archived)
                     ("d" . emacs-agents-delete)
                     ("g" . emacs-agents-refresh) ("f" . emacs-agents-files)
                     ("m" . emacs-agents-magit) ("i" . emacs-agents-details)
                     ("W" . emacs-agents-rebind-worktree)
                     ("B" . emacs-agents-board)
                     ("e" . emacs-agents-eshell)
                     ("z" . emacs-agents-focus) ("s" . emacs-agents)
                     ("q" . quit-window)))
    (evil-define-key 'motion emacs-agents-mode-map (kbd (car binding)) (cdr binding))))

(when (fboundp 'map!)
  (eval '(map! :leader (:prefix ("o a" . "agents")
                        :desc "Agent sidebar" "a" #'emacs-agents
                        :desc "Full dashboard" "d" #'emacs-agents-dashboard
                        :desc "Agent board" "b" #'emacs-agents-board
                        :desc "Focus / restore layout" "z" #'emacs-agents-focus
                        :desc "Close conversation view" "c" #'emacs-agents-close-view
                        :desc "New session" "n" #'emacs-agents-new))))
;;; doom.el ends here
