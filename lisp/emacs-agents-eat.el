;;; emacs-agents-eat.el --- Claude Code in EAT -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; EAT owns the terminal.  Claude hooks report identity and activity through a
;; private per-run event file; terminal redraws never count as assistant output.
;;; Code:
(require 'emacs-agents-transport)
(require 'emacs-agents-claude)
(require 'json)
(declare-function eat-mode "eat")
(declare-function eat-exec "eat")
(declare-function eat-term-send-string "eat")
(declare-function eat-term-display-cursor "eat")
(declare-function eat-term-display-beginning "eat")
(declare-function eat-term-in-alternative-display-p "eat")
(declare-function eat-term-input-event "eat")
(declare-function eat-emacs-mode "eat")
(declare-function eat-semi-char-mode "eat")
(defvar evil-state)
(defvar emacs-agents-eat-setup-hook nil
  "Hook for installing optional integrations in managed EAT buffers.")
(autoload 'emacs-agents-transcript "emacs-agents-transcript" nil t)
(declare-function emacs-agents--transport-fail "emacs-agents-backend")
(defvar eat-terminal)
(defvar eat-kill-buffer-on-exit)
(defvar eat-query-before-killing-running-terminal)
(defvar eat-term-scrollback-size)

(defcustom emacs-agents-eat-scrollback-size (* 8 1024 1024)
  "Characters retained in managed EAT terminals' ordinary scrollback.
This does not affect Claude's fullscreen history, which Claude itself owns."
  :type '(choice natnum (const nil)) :group 'emacs-agents)

(defcustom emacs-agents-eat-profiles
  '(((:identifier . claude-eat) (:command . ("claude"))))
  "Claude Code terminal profiles.
Each alist has :identifier (unique symbol), :command (executable and fixed
arguments), and optional :environment (NAME=VALUE strings).  Pin account
selection with CLAUDE_CONFIG_DIR in :environment.  Do not supply session,
resume, settings, or initial-prompt arguments: the adapter owns those."
  :type '(repeat alist) :group 'emacs-agents)

(defvar-local emacs-agents-eat--browsing nil)
(defvar-local emacs-agents-eat--evil-scrolling nil)

(defun emacs-agents-eat--fullscreen-p ()
  "Whether the live application owns scrolling in the alternate screen."
  (and eat-terminal (eat-term-in-alternative-display-p eat-terminal)))

(defun emacs-agents-eat--navigate (event count)
  "Send navigation EVENT COUNT times and follow the application's viewport."
  ;; Rejoin EAT's display synchronization if normal-mode movement left point
  ;; elsewhere.  Claude still owns whether its conversation follows new output.
  (goto-char (eat-term-display-cursor eat-terminal))
  (eat-term-input-event eat-terminal count event))

(defun emacs-agents-eat-scroll-up (&optional count)
  "Read older output by COUNT pages, in the application or Emacs scrollback."
  (interactive "p")
  (if (emacs-agents-eat--fullscreen-p)
      (progn
        (setq emacs-agents-eat--browsing t)
        (emacs-agents-eat--navigate 'prior (or count 1)))
    (eat-emacs-mode)
    (dotimes (_ (or count 1)) (scroll-down-command))))

(defun emacs-agents-eat-scroll-down (&optional count)
  "Read newer output by COUNT pages, in the application or Emacs scrollback."
  (interactive "p")
  (if (emacs-agents-eat--fullscreen-p)
      (emacs-agents-eat--navigate 'next (or count 1))
    (eat-emacs-mode)
    (dotimes (_ (or count 1)) (scroll-up-command))))

(defun emacs-agents-eat-latest ()
  "Return to the latest output and allow read acknowledgment again."
  (interactive)
  (when (emacs-agents-eat--fullscreen-p)
    (emacs-agents-eat--navigate 'C-end 1))
  (setq emacs-agents-eat--browsing nil)
  (goto-char (if eat-terminal (eat-term-display-cursor eat-terminal) (point-max)))
  (recenter -1))

(defun emacs-agents-eat-oldest ()
  "Show the beginning of the application's history or terminal scrollback."
  (interactive)
  (if (emacs-agents-eat--fullscreen-p)
      (progn
        (setq emacs-agents-eat--browsing t)
        (emacs-agents-eat--navigate 'C-home 1))
    (eat-emacs-mode)
    (goto-char (point-min))))

(defun emacs-agents-eat-wheel (event)
  "Route wheel EVENT to the application or ordinary Emacs scrollback."
  (interactive "e")
  (let ((window (posn-window (event-start event))))
    (when (window-live-p window)
      (with-selected-window window
        (if (emacs-agents-eat--fullscreen-p)
            (progn
              (setq emacs-agents-eat--browsing t)
              (goto-char (eat-term-display-cursor eat-terminal))
              (eat-term-input-event eat-terminal 1 event
                                   (posn-at-point (eat-term-display-beginning eat-terminal))))
          (eat-emacs-mode)
          (mwheel-scroll event))))))

(defvar emacs-agents-eat-navigation-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding '(("<prior>" . emacs-agents-eat-scroll-up)
                       ("<next>" . emacs-agents-eat-scroll-down)
                       ("C-<home>" . emacs-agents-eat-oldest)
                       ("C-<end>" . emacs-agents-eat-latest)
                       ("C-c C-b" . emacs-agents-eat-latest)
                       ("<wheel-up>" . emacs-agents-eat-wheel)
                       ("<wheel-down>" . emacs-agents-eat-wheel)
                       ("<mouse-4>" . emacs-agents-eat-wheel)
                       ("<mouse-5>" . emacs-agents-eat-wheel)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map))

(defvar emacs-agents-eat--navigation-maps
  `((emacs-agents-eat--evil-scrolling
     . ,(let ((map (make-sparse-keymap)))
          (define-key map (kbd "C-u") #'emacs-agents-eat-scroll-up)
          (define-key map (kbd "C-d") #'emacs-agents-eat-scroll-down)
          map))
    (emacs-agents-eat-navigation-mode . ,emacs-agents-eat-navigation-mode-map)))

(define-minor-mode emacs-agents-eat-navigation-mode
  "Route managed terminal scrolling to the owner of the conversation history."
  :lighter (:eval (when emacs-agents-eat--browsing " History:C-c C-b"))
  ;; Precede both Evil and EAT's mouse/input maps, only in this buffer.
  (setq-local emulation-mode-map-alists
              (delq 'emacs-agents-eat--navigation-maps
                    (copy-sequence emulation-mode-map-alists)))
  (when emacs-agents-eat-navigation-mode
    (push 'emacs-agents-eat--navigation-maps emulation-mode-map-alists))
  (unless emacs-agents-eat-navigation-mode
    (setq emacs-agents-eat--evil-scrolling nil)))

(defun emacs-agents-eat-configs ()
  "Return configured EAT profiles without starting anything."
  (mapcar (lambda (config)
            (let ((copy (copy-tree config)))
              (unless (map-elt copy :agent) (setf (alist-get :agent copy) "Claude"))
              (unless (map-elt copy :account)
                (setf (alist-get :account copy) (symbol-name (map-elt copy :identifier))))
              copy))
          emacs-agents-eat-profiles))

(defun emacs-agents-eat-send-escape ()
  "Send Escape to Claude without leaving Evil insert state."
  (interactive)
  (eat-term-send-string eat-terminal "\e")
  ;; Claude has no Stop hook for a user interrupt.  Do not claim it finished.
  (when emacs-agents-claude--turn-active
    (funcall (emacs-agents-transport-callback emacs-agents-claude--transport)
             "live" "unknown")))

(defun emacs-agents-eat--read-position ()
  "Return the terminal cursor, excluding unused rows below the prompt."
  ;; In fullscreen the prompt stays visible even while reading old messages.
  (unless emacs-agents-eat--browsing
    (if eat-terminal (eat-term-display-cursor eat-terminal) (point-max))))

(defun emacs-agents-eat-sync-evil-state ()
  "Use Emacs navigation in Evil normal/visual states, terminal input in insert."
  (when (and (eq emacs-agents--backend-kind 'eat) eat-terminal)
    (setq emacs-agents-eat--evil-scrolling
          (and emacs-agents-eat-navigation-mode (memq evil-state '(normal motion))))
    (if (memq evil-state '(insert emacs))
        (progn
          (eat-semi-char-mode)
          (goto-char (eat-term-display-cursor eat-terminal)))
      (eat-emacs-mode))))

(defun emacs-agents-eat-setup-evil ()
  "Install buffer-local Evil state integration for a managed EAT buffer."
  (when (bound-and-true-p evil-local-mode)
    (dolist (hook '(evil-normal-state-entry-hook evil-visual-state-entry-hook
                    evil-insert-state-entry-hook evil-emacs-state-entry-hook
                    evil-motion-state-entry-hook evil-operator-state-entry-hook))
      (add-hook hook #'emacs-agents-eat-sync-evil-state nil t))
    (emacs-agents-eat-sync-evil-state)))

(defun emacs-agents-eat--launch (command prepare)
  "Launch COMMAND in EAT, calling PREPARE after setting the major mode."
  (let ((eat-kill-buffer-on-exit nil)
        (eat-query-before-killing-running-terminal nil))
    (eat-mode)
    (funcall prepare)
    (setq-local eat-term-scrollback-size emacs-agents-eat-scrollback-size
                emacs-agents--read-position-function #'emacs-agents-eat--read-position)
    (emacs-agents-eat-navigation-mode 1)
    (use-local-map (copy-keymap (current-local-map)))
    (local-set-key (kbd "C-<escape>") #'emacs-agents-eat-send-escape)
    (local-set-key (kbd "C-c C-t") #'emacs-agents-transcript)
    (add-hook 'eat-exit-hook #'emacs-agents-claude--exited nil t)
    (eat-exec (current-buffer) (buffer-name) (car command) nil (cdr command))))

(defun emacs-agents-eat-start (profile directory conversation callback)
  "Start Claude PROFILE in EAT in DIRECTORY, restoring CONVERSATION.
Report lifecycle observations to CALLBACK."
  (unless (require 'eat nil t) (user-error "Install EAT to use a Claude terminal profile"))
  (emacs-agents-claude-start
   profile (seq-find (lambda (entry) (equal profile (symbol-name (map-elt entry :identifier))))
                     emacs-agents-eat-profiles)
   directory conversation callback 'eat #'emacs-agents-eat--launch 'emacs-agents-eat-setup-hook))

;; Existing runs can hold these function symbols in timers/hooks during reload.
(defalias 'emacs-agents-eat--poll #'emacs-agents-claude--poll)
(defalias 'emacs-agents-eat--cancel-timer #'emacs-agents-claude--cancel-timer)
(defalias 'emacs-agents-eat--exited #'emacs-agents-claude--exited)
(defalias 'emacs-agents-eat-stop #'emacs-agents-claude-stop)
(defalias 'emacs-agents-eat-metadata #'emacs-agents-claude-metadata)

(provide 'emacs-agents-eat)
;;; emacs-agents-eat.el ends here
