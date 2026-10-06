;;; mx-machina-doom.el --- Optional Doom and Evil bindings -*- lexical-binding: t; -*-

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
;; Require this library from Doom's config.el to enable the optional bindings.
;;; Code:
(require 'mx-machina)
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-define-key* "evil-core")
(declare-function mx-machina-transcript-refresh "mx-machina-transcript")
(declare-function mx-machina-transcript-return "mx-machina-transcript")
(defvar mx-machina-actions-mode-map)
(defvar mx-machina-board-mode-map)
(defvar mx-machina-diagnostics-mode-map)
(defvar mx-machina-transcript-mode-map)

(with-eval-after-load 'evil
  (evil-set-initial-state 'mx-machina-actions-mode 'motion)
  (with-eval-after-load 'mx-machina-actions
    (dolist (key '("o" "x" "r" "i" "W" "R" "M" "u" "e" "f" "a" "s" "d" "TAB" "n" "N" "B" "D" "A" "]" "[" "RET" "g" "q" "?"))
      (evil-define-key* 'motion mx-machina-actions-mode-map (kbd key)
        (lookup-key mx-machina-actions-mode-map (kbd key))))
    (evil-define-key* 'motion mx-machina-actions-mode-map
      (kbd "j") #'next-line (kbd "k") #'previous-line))
  (evil-set-initial-state 'mx-machina-board-mode 'motion)
  (with-eval-after-load 'mx-machina-board
    (dolist (key '("j" "k" "h" "l" "TAB" "RET" "f" "g" "n" "i" "q" "]" "[" "?"))
      (evil-define-key* 'motion mx-machina-board-mode-map (kbd key)
        (lookup-key mx-machina-board-mode-map (kbd key)))))
  (add-hook 'mx-machina-eat-setup-hook #'mx-machina-eat-setup-evil)
  (add-hook 'mx-machina-vterm-setup-hook #'mx-machina-vterm-setup-evil)
  (evil-set-initial-state 'mx-machina-diagnostics-mode 'normal)
  (with-eval-after-load 'mx-machina-diagnostics
    (evil-define-key* 'normal mx-machina-diagnostics-mode-map
      (kbd "q") #'mx-machina-diagnostics-return
      (kbd "g") #'mx-machina-diagnostics-refresh
      (kbd "W") #'mx-machina-rebind-worktree
      (kbd "R") #'mx-machina-retry
      (kbd "?") #'mx-machina-actions
      (kbd "w") #'mx-machina-diagnostics-copy))
  (evil-set-initial-state 'mx-machina-transcript-mode 'normal)
  (with-eval-after-load 'mx-machina-transcript
    (evil-define-key* 'normal mx-machina-transcript-mode-map
      (kbd "q") #'mx-machina-transcript-return
      (kbd "g") #'mx-machina-transcript-refresh))
  (evil-define-key* 'normal mx-machina-conversation-mode-map
    (kbd "q") #'mx-machina-close-view)
  (evil-set-initial-state 'mx-machina-sidebar-mode 'motion)
  (evil-set-initial-state 'mx-machina-archive-mode 'motion)
  (evil-define-key* 'motion mx-machina-archive-mode-map
    (kbd "RET") #'mx-machina-restore
    (kbd "r") #'mx-machina-restore
    (kbd "A") #'mx-machina-dashboard
    (kbd "d") #'mx-machina-delete)
  (dolist (binding '(("j" . mx-machina-sidebar-next) ("k" . mx-machina-sidebar-previous)
                     ("n" . mx-machina-new) ("RET" . mx-machina-sidebar-open)
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
                     ("TAB" . mx-machina-sidebar-expand) ("z" . mx-machina-focus)
                     ("D" . mx-machina-dashboard) ("c" . mx-machina-close-view)
                     ("q" . quit-window)))
    (evil-define-key* 'motion mx-machina-sidebar-mode-map (kbd (car binding)) (cdr binding)))
  (evil-set-initial-state 'mx-machina-mode 'motion)
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
    (evil-define-key* 'motion mx-machina-mode-map (kbd (car binding)) (cdr binding))))

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

(provide 'mx-machina-doom)
;;; mx-machina-doom.el ends here
