;;; activate.el --- Activate only the disposable package installation -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'package)
(setq package-archives nil
      package-enable-at-startup nil)
(package-initialize)
(unless (package-installed-p 'mx-machina)
  (error "Archive was not installed"))
