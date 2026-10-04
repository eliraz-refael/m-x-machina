;;; doom.el --- Optional Doom and Evil setup -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Load this file; it resolves the package location relative to itself.
(add-to-list 'load-path
             (expand-file-name "../lisp" (file-name-directory (or load-file-name buffer-file-name))))
(require 'mx-machina)

(with-eval-after-load 'evil
  (evil-set-initial-state 'emacs-agents-actions-mode 'motion)
  (with-eval-after-load 'emacs-agents-actions
    (dolist (key '("o" "x" "r" "i" "W" "R" "M" "u" "e" "f" "a" "s" "d" "TAB" "n" "N" "B" "D" "A" "]" "[" "RET" "g" "q" "?"))
      (evil-define-key 'motion emacs-agents-actions-mode-map (kbd key)
        (lookup-key emacs-agents-actions-mode-map (kbd key))))
    (evil-define-key 'motion emacs-agents-actions-mode-map
      (kbd "j") #'next-line (kbd "k") #'previous-line))
  (evil-set-initial-state 'emacs-agents-board-mode 'motion)
  (with-eval-after-load 'emacs-agents-board
    (dolist (key '("j" "k" "h" "l" "TAB" "RET" "f" "g" "n" "i" "q" "]" "[" "?"))
      (evil-define-key 'motion emacs-agents-board-mode-map (kbd key)
        (lookup-key emacs-agents-board-mode-map (kbd key)))))
  (add-hook 'emacs-agents-eat-setup-hook #'emacs-agents-eat-setup-evil)
  (add-hook 'emacs-agents-vterm-setup-hook #'emacs-agents-vterm-setup-evil)
  (evil-set-initial-state 'emacs-agents-diagnostics-mode 'normal)
  (with-eval-after-load 'emacs-agents-diagnostics
    (evil-define-key 'normal emacs-agents-diagnostics-mode-map
      (kbd "q") #'emacs-agents-diagnostics-return
      (kbd "g") #'emacs-agents-diagnostics-refresh
      (kbd "W") #'mx-machina-rebind-worktree
      (kbd "R") #'mx-machina-retry
      (kbd "?") #'mx-machina-actions
      (kbd "w") #'emacs-agents-diagnostics-copy))
  (evil-set-initial-state 'emacs-agents-transcript-mode 'normal)
  (with-eval-after-load 'emacs-agents-transcript
    (evil-define-key 'normal emacs-agents-transcript-mode-map
      (kbd "q") #'emacs-agents-transcript-return
      (kbd "g") #'emacs-agents-transcript-refresh))
  (evil-define-key 'normal emacs-agents-conversation-mode-map
    (kbd "q") #'mx-machina-close-view)
  (evil-set-initial-state 'emacs-agents-sidebar-mode 'motion)
  (evil-set-initial-state 'emacs-agents-archive-mode 'motion)
  (evil-define-key 'motion emacs-agents-archive-mode-map
    (kbd "RET") #'mx-machina-restore
    (kbd "r") #'mx-machina-restore
    (kbd "A") #'mx-machina-dashboard
    (kbd "d") #'mx-machina-delete)
  (dolist (binding '(("j" . emacs-agents-sidebar-next) ("k" . emacs-agents-sidebar-previous)
                     ("n" . mx-machina-new) ("RET" . emacs-agents-sidebar-open)
                     ("N" . mx-machina-new-folder) ("M" . mx-machina-move)
                     ("R" . mx-machina-rename) ("u" . mx-machina-mark-read)
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
                     ("TAB" . emacs-agents-sidebar-expand) ("z" . mx-machina-focus)
                     ("D" . mx-machina-dashboard) ("c" . mx-machina-close-view)
                     ("q" . quit-window)))
    (evil-define-key 'motion emacs-agents-sidebar-mode-map (kbd (car binding)) (cdr binding)))
  (evil-set-initial-state 'emacs-agents-mode 'motion)
  (dolist (binding '(("j" . next-line) ("k" . previous-line)
                     ("n" . mx-machina-new) ("RET" . mx-machina-open)
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
                     ("z" . mx-machina-focus) ("s" . mx-machina)
                     ("q" . quit-window)))
    (evil-define-key 'motion emacs-agents-mode-map (kbd (car binding)) (cdr binding))))

(when (fboundp 'map!)
  (eval '(map! :leader (:prefix ("o a" . "agents")
                        :desc "Agent sidebar" "a" #'mx-machina
                        :desc "Full dashboard" "d" #'mx-machina-dashboard
                        :desc "Agent board" "b" #'mx-machina-board
                        :desc "Contextual actions" "?" #'mx-machina-actions
                        :desc "Next agent needing attention" "]" #'mx-machina-next-attention
                        :desc "Previous agent needing attention" "[" #'mx-machina-previous-attention
                        :desc "Focus / restore layout" "z" #'mx-machina-focus
                        :desc "Close conversation view" "c" #'mx-machina-close-view
                        :desc "New session" "n" #'mx-machina-new))))
;;; doom.el ends here
