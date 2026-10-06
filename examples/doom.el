;;; doom.el --- Optional Doom and Evil setup -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Load this file; it resolves the package location relative to itself.
(add-to-list 'load-path
             (expand-file-name "../lisp" (file-name-directory (or load-file-name buffer-file-name))))
(require 'mx-machina-doom)
;;; doom.el ends here
