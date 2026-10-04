;;; mx-machina.el --- M-x Machina: your coding-agent workspace -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; URL: https://github.com/eliraz-refael/m-x-machina
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes
;;; Commentary:
;; Public Emacs commands use mx-machina; the external CLI is mxm.
;; The emacs-agents implementation and settings retain their names so existing
;; configurations and saved agents continue to work without migration.
;;; Code:
(require 'emacs-agents)
(autoload 'emacs-agents-messaging-ready "emacs-agents-messaging" nil t)

;;;###autoload
(defalias 'mx-machina #'emacs-agents)

;;;###autoload
(defalias 'mx-machina-new #'emacs-agents-new)

;;;###autoload
(defalias 'mx-machina-new-folder #'emacs-agents-new-folder)

;;;###autoload
(defalias 'mx-machina-move #'emacs-agents-move)

;;;###autoload
(defalias 'mx-machina-rename #'emacs-agents-rename)

;;;###autoload
(defalias 'mx-machina-mark-read #'emacs-agents-mark-read)

;;;###autoload
(defalias 'mx-machina-open #'emacs-agents-open)

;;;###autoload
(defalias 'mx-machina-stop #'emacs-agents-stop)

;;;###autoload
(defalias 'mx-machina-archive #'emacs-agents-archive)

;;;###autoload
(defalias 'mx-machina-archived #'emacs-agents-archived)

;;;###autoload
(defalias 'mx-machina-restore #'emacs-agents-restore)

;;;###autoload
(defalias 'mx-machina-delete #'emacs-agents-delete)

;;;###autoload
(defalias 'mx-machina-refresh #'emacs-agents-refresh)

;;;###autoload
(defalias 'mx-machina-files #'emacs-agents-files)

;;;###autoload
(defalias 'mx-machina-magit #'emacs-agents-magit)

;;;###autoload
(defalias 'mx-machina-details #'emacs-agents-details)

;;;###autoload
(defalias 'mx-machina-board #'emacs-agents-board)

;;;###autoload
(defalias 'mx-machina-actions #'emacs-agents-actions)

;;;###autoload
(defalias 'mx-machina-next-attention #'emacs-agents-next-attention)

;;;###autoload
(defalias 'mx-machina-previous-attention #'emacs-agents-previous-attention)

;;;###autoload
(defalias 'mx-machina-next-waiting #'emacs-agents-next-waiting)

;;;###autoload
(defalias 'mx-machina-previous-waiting #'emacs-agents-previous-waiting)

;;;###autoload
(defalias 'mx-machina-next-unread #'emacs-agents-next-unread)

;;;###autoload
(defalias 'mx-machina-previous-unread #'emacs-agents-previous-unread)

;;;###autoload
(defalias 'mx-machina-eshell #'emacs-agents-eshell)

;;;###autoload
(defalias 'mx-machina-focus #'emacs-agents-focus)

;;;###autoload
(defalias 'mx-machina-dashboard #'emacs-agents-dashboard)

;;;###autoload
(defalias 'mx-machina-close-view #'emacs-agents-close-view)

;;;###autoload
(defalias 'mx-machina-diagnostics #'emacs-agents-diagnostics)

;;;###autoload
(defalias 'mx-machina-rebind-worktree #'emacs-agents-rebind-worktree)

;;;###autoload
(defalias 'mx-machina-retry #'emacs-agents-retry)

;;;###autoload
(defalias 'mx-machina-transcript #'emacs-agents-transcript)

;;;###autoload
(defalias 'mx-machina-status-mode #'emacs-agents-status-mode)

;;;###autoload
(defalias 'mx-machina-messaging-mode #'emacs-agents-messaging-mode)

;;;###autoload
(defalias 'mx-machina-messaging-ready #'emacs-agents-messaging-ready)

(provide 'mx-machina)
;;; mx-machina.el ends here
