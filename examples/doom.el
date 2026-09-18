;;; doom.el --- Optional Doom and Evil setup -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Load this file; it resolves the package location relative to itself.
(add-to-list 'load-path
             (expand-file-name "../lisp" (file-name-directory (or load-file-name buffer-file-name))))
(require 'emacs-agents)

(with-eval-after-load 'evil
  (evil-set-initial-state 'emacs-agents-mode 'motion)
  (dolist (binding '(("j" . next-line) ("k" . previous-line)
                     ("n" . emacs-agents-new) ("RET" . emacs-agents-open)
                     ("r" . emacs-agents-open) ("x" . emacs-agents-stop)
                     ("g" . emacs-agents-refresh) ("f" . emacs-agents-files)
                     ("m" . emacs-agents-magit) ("i" . emacs-agents-details)
                     ("q" . quit-window)))
    (evil-define-key 'motion emacs-agents-mode-map (kbd (car binding)) (cdr binding))))

(when (fboundp 'map!)
  (eval '(map! :leader (:prefix ("o a" . "agents")
                        :desc "Dashboard" "a" #'emacs-agents
                        :desc "New session" "n" #'emacs-agents-new))))
;;; doom.el ends here
