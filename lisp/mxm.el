;;; mxm.el --- M-x Machina: your coding-agent workspace -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; URL: https://github.com/eliraz-refael/m-x-machina
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes
;;; Commentary:
;; Public entry points for M-x Machina.  The emacs-agents implementation,
;; customization variables and registry paths remain compatible with existing
;; configurations.  Both entry points manage the same agents and conversations.
;;; Code:
(require 'emacs-agents)

;;;###autoload
(defalias 'mxm #'emacs-agents
  "Open the M-x Machina agent sidebar.")
;;;###autoload
(defalias 'mxm-new #'emacs-agents-new
  "Create a named M-x Machina agent, optionally in a new worktree.")
;;;###autoload
(defalias 'mxm-board #'emacs-agents-board
  "Open the M-x Machina agent board.")
;;;###autoload
(defalias 'mxm-dashboard #'emacs-agents-dashboard
  "Open the M-x Machina session table.")
;;;###autoload
(defalias 'mxm-messaging-mode #'emacs-agents-messaging-mode
  "Toggle the local mxm CLI message service.")

(provide 'mxm)
;;; mxm.el ends here
