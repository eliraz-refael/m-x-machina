;;; emacs-agents-transport.el --- Shared adapter identity -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Kept separate so adapters can be compiled and loaded independently.
;;; Code:
(require 'cl-lib)
(cl-defstruct (emacs-agents-transport (:constructor emacs-agents--transport-create))
  buffer callback conversation ready failed stopping)

(defvar-local emacs-agents--backend-kind 'agent-shell)
(defvar-local emacs-agents--read-position-function nil
  "Optional buffer-local function returning the latest visible output position.")
(defvar emacs-agents-backend-event-hook nil
  "Functions receiving TRANSPORT, normalized event KIND, and DATA.
Kinds include `message' (new output), `metadata' (model information),
`prompt' (:hash), `reply-chunk' (text), and `turn-ended' (:text/:error).
Text capture for Claude terminal replies is enabled only by a request marker.
Adapters must suppress transcript replay and events from stopped transports.")

(provide 'emacs-agents-transport)
;;; emacs-agents-transport.el ends here
