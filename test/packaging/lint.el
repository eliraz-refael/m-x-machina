;;; lint.el --- Package checks and explicit optional-integration exceptions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'package-lint)
(require 'checkdoc)
(setq package-lint-main-file (expand-file-name "lisp/mx-machina.el")
      checkdoc-autofix-flag nil
      ;; Older Emacs flags nouns such as "changes" as non-imperative verbs.
      checkdoc-verb-check-experimental-flag nil
      checkdoc-spellcheck-documentation-flag nil)
(let ((exceptions '(("mx-machina-agent-shell.el" . (agent-shell acp))
                    ("mx-machina-doom.el" . (evil mx-machina-actions mx-machina-board
                                                mx-machina-diagnostics mx-machina-transcript))))
      (failures 0))
  (dolist (file (directory-files "lisp" t "[.]el$"))
    (with-temp-buffer
      (insert-file-contents file)
      (setq buffer-file-name file)
      (emacs-lisp-mode)
      (dolist (issue (package-lint-buffer))
        (pcase-let ((`(,line ,column ,severity ,message) issue))
          (goto-char (point-min))
          (forward-line (1- line))
          (let* ((form (ignore-errors (read (current-buffer))))
                 (feature (and (eq (car-safe form) 'with-eval-after-load)
                               (cadr (cadr form))))
                 (allowed (and (eq severity 'warning)
                               (equal message "`with-eval-after-load' is for use in configurations, and should rarely be used in packages.")
                               (memq feature (cdr (assoc (file-name-nondirectory file) exceptions))))))
            (princ (format "%s:%s:%s: %s %s\n" file line column
                           (if allowed "REVIEWED OPTIONAL INTEGRATION:" severity) message))
            (unless allowed (cl-incf failures)))))
      (checkdoc-current-buffer t)))
  (when-let* ((buffer (get-buffer "*Style Warnings*")))
    (with-current-buffer buffer
      (goto-char (point-min))
      (while (re-search-forward "^.*[.]el:[0-9]+:.*$" nil t)
        (princ (concat (match-string 0) "\n"))
        (cl-incf failures))))
  (when (> failures 0) (error "%s unreviewed package/checkdoc issues" failures)))
(princ "PASS package-lint (documented optional-integration exceptions) and checkdoc\n")
