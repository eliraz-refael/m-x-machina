;;; mx-machina-backend.el --- Agent adapter boundary -*- lexical-binding: t; -*-

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
;; Session identity and views are shared by structured and terminal adapters.
;;; Code:
(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)

(require 'mx-machina-transport)
(require 'mx-machina-claude)

(defun mx-machina-backend-configs ()
  "Return available structured and terminal profiles without launching agents."
  (let* ((configs
          (apply #'append
                 (mapcar (lambda (entry)
                           (mapcar (lambda (config)
                                     (let ((copy (copy-tree config)))
                                       (setf (alist-get :interface copy) (car entry))
                                       copy))
                                   (cdr entry)))
                         (list (cons 'agent-shell (mx-machina-agent-shell-configs))
                               (cons 'eat (mx-machina-eat-configs))
                               (cons 'vterm (mx-machina-vterm-configs))))))
         (ids (mapcar (lambda (config) (map-elt config :identifier)) configs)))
    (unless (= (length ids) (length (delete-dups (copy-sequence ids))))
      (user-error "Agent profile identifiers must be unique across backends"))
    configs))

(defun mx-machina--terminal-transport-p (transport)
  "Return non-nil when TRANSPORT uses a Claude terminal."
  (let ((buffer (mx-machina-transport-buffer transport)))
    (and (buffer-live-p buffer)
         (memq (buffer-local-value 'mx-machina--backend-kind buffer) '(eat vterm)))))

(defun mx-machina-backend-read-profile ()
  "Choose an agent, account and interface, returning the durable profile ID."
  (let ((configs (mx-machina-backend-configs)))
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

(defun mx-machina-backend-start (profile directory conversation callback)
  "Start PROFILE in DIRECTORY, restoring CONVERSATION and calling CALLBACK."
  (let ((config (seq-find (lambda (entry) (equal profile (symbol-name (map-elt entry :identifier))))
                          (mx-machina-backend-configs))))
    (pcase (map-elt config :interface)
      ('eat (mx-machina-eat-start profile directory conversation callback))
      ('vterm (mx-machina-vterm-start profile directory conversation callback))
      ('agent-shell (mx-machina-agent-shell-start profile directory conversation callback))
      (_ (user-error "Restore the saved profile: %s" profile)))))

(defun mx-machina-backend-process (transport)
  "Return TRANSPORT's process."
  (if (mx-machina--terminal-transport-p transport)
      (get-buffer-process (mx-machina-transport-buffer transport))
    (mx-machina-agent-shell-process transport)))

(defun mx-machina-backend-stop (transport)
  "Stop TRANSPORT, retaining its buffer and conversation identity."
  (if (mx-machina--terminal-transport-p transport)
      (mx-machina-claude-stop transport)
    (mx-machina-agent-shell-stop transport)))

(defun mx-machina-backend-metadata (transport)
  "Return TRANSPORT's reported metadata."
  (if (mx-machina--terminal-transport-p transport)
      (mx-machina-claude-metadata transport)
    (mx-machina-agent-shell-metadata transport)))

(defun mx-machina--transport-fail (transport message)
  "Record MESSAGE and stop TRANSPORT without permitting replacement."
  (unless (mx-machina-transport-failed transport)
    (setf (mx-machina-transport-failed transport) t)
    (funcall (mx-machina-transport-callback transport) "failed" "unknown" nil message)
    (run-at-time 0 nil #'mx-machina-backend-stop transport)))

(require 'mx-machina-agent-shell)
(require 'mx-machina-eat)
(require 'mx-machina-vterm)
(provide 'mx-machina-backend)
;;; mx-machina-backend.el ends here
