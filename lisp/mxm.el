;;; mxm.el --- Compatibility entry points for M-x Machina -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Use mx-machina for Emacs commands.  The external CLI remains mxm.
;;; Code:
(require 'mx-machina)

;;;###autoload
(defalias 'mxm #'mx-machina)

;;;###autoload
(defalias 'mxm-new #'mx-machina-new)

;;;###autoload
(defalias 'mxm-board #'mx-machina-board)

;;;###autoload
(defalias 'mxm-dashboard #'mx-machina-dashboard)

;;;###autoload
(defalias 'mxm-messaging-mode #'mx-machina-messaging-mode)

(provide 'mxm)
;;; mxm.el ends here
