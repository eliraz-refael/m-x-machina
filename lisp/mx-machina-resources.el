;;; mx-machina-resources.el --- Locate bundled runtime helpers -*- lexical-binding: t; -*-

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
;; Package archives flatten lisp/ into their root; Git checkouts retain it.
;;; Code:

(defconst mx-machina--resource-directory
  (let ((directory (file-name-directory (or load-file-name buffer-file-name))))
    (if (equal (file-name-nondirectory (directory-file-name directory)) "lisp")
        (expand-file-name "../" directory)
      directory))
  "Directory containing this installation's bundled runtime resources.")

(defun mx-machina--resource-file (name)
  "Return the readable bundled resource NAME, or report an incomplete install."
  (let ((file (expand-file-name name mx-machina--resource-directory)))
    (unless (file-readable-p file)
      (error "M-x Machina resource missing: %s; reinstall the complete package" file))
    file))

(provide 'mx-machina-resources)
;;; mx-machina-resources.el ends here
