;;; emacs-agents-backend.el --- Agent adapter boundary -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Session identity and views are shared by structured and terminal adapters.
;;; Code:
(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)

(require 'emacs-agents-transport)
(require 'emacs-agents-claude)

(defun emacs-agents-backend-configs ()
  "Return available structured and terminal profiles without launching agents."
  (let* ((configs
          (apply #'append
                 (mapcar (lambda (entry)
                           (mapcar (lambda (config)
                                     (let ((copy (copy-tree config)))
                                       (setf (alist-get :interface copy) (car entry))
                                       copy))
                                   (cdr entry)))
                         (list (cons 'agent-shell (emacs-agents-agent-shell-configs))
                               (cons 'eat (emacs-agents-eat-configs))
                               (cons 'vterm (emacs-agents-vterm-configs))))))
         (ids (mapcar (lambda (config) (map-elt config :identifier)) configs)))
    (unless (= (length ids) (length (delete-dups (copy-sequence ids))))
      (user-error "Agent profile identifiers must be unique across backends"))
    configs))

(defun emacs-agents--terminal-transport-p (transport)
  "Return non-nil when TRANSPORT uses a Claude terminal."
  (let ((buffer (emacs-agents-transport-buffer transport)))
    (and (buffer-live-p buffer)
         (memq (buffer-local-value 'emacs-agents--backend-kind buffer) '(eat vterm)))))

(defun emacs-agents-backend-read-profile ()
  "Choose an agent, account and interface, returning the durable profile ID."
  (let ((configs (emacs-agents-backend-configs)))
    (unless configs (user-error "Configure an agent profile first"))
    (dolist (field '((:agent . "Agent: ") (:account . "Account: ") (:interface . "Interface: ")))
      (let* ((label (lambda (config)
                      (format "%s" (or (map-elt config (car field))
                                       (if (eq (car field) :agent)
                                           (or (map-elt config :mode-line-name)
                                               (map-elt config :identifier))
                                         "Default")))))
             (choices (delete-dups (mapcar label configs)))
             (choice (completing-read (cdr field) choices nil t nil nil (car choices))))
        (setq configs (seq-filter (lambda (config) (equal choice (funcall label config))) configs))))
    (let ((ids (mapcar (lambda (config) (symbol-name (map-elt config :identifier))) configs)))
      (if (= (length ids) 1) (car ids)
        (completing-read "Profile: " ids nil t)))))

(defun emacs-agents-backend-start (profile directory conversation callback)
  "Start PROFILE in DIRECTORY, restoring CONVERSATION and calling CALLBACK."
  (let ((config (seq-find (lambda (entry) (equal profile (symbol-name (map-elt entry :identifier))))
                          (emacs-agents-backend-configs))))
    (pcase (map-elt config :interface)
      ('eat (emacs-agents-eat-start profile directory conversation callback))
      ('vterm (emacs-agents-vterm-start profile directory conversation callback))
      ('agent-shell (emacs-agents-agent-shell-start profile directory conversation callback))
      (_ (user-error "Restore the saved profile: %s" profile)))))

(defun emacs-agents-backend-process (transport)
  "Return TRANSPORT's process."
  (if (emacs-agents--terminal-transport-p transport)
      (get-buffer-process (emacs-agents-transport-buffer transport))
    (emacs-agents-agent-shell-process transport)))

(defun emacs-agents-backend-stop (transport)
  "Stop TRANSPORT, retaining its buffer and conversation identity."
  (if (emacs-agents--terminal-transport-p transport)
      (emacs-agents-claude-stop transport)
    (emacs-agents-agent-shell-stop transport)))

(defun emacs-agents-backend-metadata (transport)
  "Return TRANSPORT's reported metadata."
  (if (emacs-agents--terminal-transport-p transport)
      (emacs-agents-claude-metadata transport)
    (emacs-agents-agent-shell-metadata transport)))

(defun emacs-agents--transport-fail (transport message)
  "Record MESSAGE and stop TRANSPORT without permitting replacement."
  (unless (emacs-agents-transport-failed transport)
    (setf (emacs-agents-transport-failed transport) t)
    (funcall (emacs-agents-transport-callback transport) "failed" "unknown" nil message)
    (run-at-time 0 nil #'emacs-agents-backend-stop transport)))

(require 'emacs-agents-agent-shell)
(require 'emacs-agents-eat)
(require 'emacs-agents-vterm)
(provide 'emacs-agents-backend)
;;; emacs-agents-backend.el ends here
