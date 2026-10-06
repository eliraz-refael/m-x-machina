;;; probe.el --- Exercise generated autoloads and installed resources -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'cl-lib)
(cl-assert (not (featurep 'mx-machina)))
(dolist (command '(mx-machina mx-machina-new mx-machina-board mx-machina-actions
                  mx-machina-next-attention mx-machina-transcript mx-machina-status-mode
                  mx-machina-messaging-mode))
  (cl-assert (autoloadp (symbol-function command))))
(mx-machina)
(cl-assert (derived-mode-p 'mx-machina-sidebar-mode))
(cl-assert (file-in-directory-p (symbol-file 'mx-machina) package-user-dir))
(cl-assert (string-suffix-p ".elc" (symbol-file 'mx-machina)))
(require 'mx-machina-messaging)
(dolist (file (list mx-machina-claude--hook-script mx-machina-messaging--script
                  (mx-machina--resource-file "scripts/emacs-agents")))
  (cl-assert (file-in-directory-p file package-user-dir))
  (cl-assert (file-readable-p file)))
;; Optional configuration can be loaded without Doom/Evil/terminal dependencies.
(require 'mx-machina-doom)
(dolist (feature '(doom evil eat vterm agent-shell))
  (cl-assert (not (featurep feature))))
(mx-machina-shutdown)
(princ "PASS installed bytecode, generated autoloads, bundled scripts, optional dependencies\n")
