;;; build.el --- Build the exact recipe from an isolated local snapshot -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'package-build)
(setq package-build-working-dir (expand-file-name "working/")
      package-build-archive-dir (expand-file-name "archive/")
      package-build-recipes-dir (expand-file-name "recipes/")
      ;; Use the committed snapshot prepared by check-package, not the unpublished
      ;; branch's upstream.  The recipe and its file specification are unchanged.
      package-build--inhibit-fetch 'strict)
(package-build-archive "mx-machina" t)
(unless (= (length (directory-files package-build-archive-dir nil "[.]tar$")) 1)
  (error "Expected exactly one built archive"))
