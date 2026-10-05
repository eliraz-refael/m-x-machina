;;; mx-machina-eat.el --- Claude Code in EAT -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; EAT owns the terminal.  Claude hooks report identity and activity through a
;; private per-run event file; terminal redraws never count as assistant output.
;;; Code:
(require 'mwheel)
(require 'mx-machina-transport)
(require 'mx-machina-claude)
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
(defvar mx-machina-eat-setup-hook nil
  "Hook for installing optional integrations in managed EAT buffers.")
(autoload 'mx-machina-transcript "mx-machina-transcript" nil t)
(declare-function mx-machina--transport-fail "mx-machina-backend")
(defvar eat-terminal)
(defvar eat-kill-buffer-on-exit)
(defvar eat-query-before-killing-running-terminal)
(defvar eat-term-scrollback-size)

(defcustom mx-machina-eat-scrollback-size (* 8 1024 1024)
  "Characters retained in managed EAT terminals' ordinary scrollback.
This does not affect Claude's fullscreen history, which Claude itself owns."
  :type '(choice natnum (const nil)) :group 'mx-machina)

(defcustom mx-machina-eat-profiles
  '(((:identifier . claude-eat) (:command . ("claude"))))
  "Claude Code terminal profiles.
Each alist has :identifier (unique symbol), :command (executable and fixed
arguments), and optional :environment (NAME=VALUE strings).  Pin account
selection with CLAUDE_CONFIG_DIR in :environment.  Do not supply session,
resume, settings, or initial-prompt arguments: the adapter owns those."
  :type '(repeat alist) :group 'mx-machina)

(defvar-local mx-machina-eat--browsing nil)
(defvar-local mx-machina-eat--evil-scrolling nil)

(defun mx-machina-eat--fullscreen-p ()
  "Whether the live application owns scrolling in the alternate screen."
  (and eat-terminal (eat-term-in-alternative-display-p eat-terminal)))

(defun mx-machina-eat--navigate (event count)
  "Send navigation EVENT COUNT times and follow the application's viewport."
  ;; Rejoin EAT's display synchronization if normal-mode movement left point
  ;; elsewhere.  Claude still owns whether its conversation follows new output.
  (goto-char (eat-term-display-cursor eat-terminal))
  (eat-term-input-event eat-terminal count event))

(defun mx-machina-eat-scroll-up (&optional count)
  "Read older output by COUNT pages, in the application or Emacs scrollback."
  (interactive "p")
  (if (mx-machina-eat--fullscreen-p)
      (progn
        (setq mx-machina-eat--browsing t)
        (mx-machina-eat--navigate 'prior (or count 1)))
    (eat-emacs-mode)
    (dotimes (_ (or count 1)) (scroll-down-command))))

(defun mx-machina-eat-scroll-down (&optional count)
  "Read newer output by COUNT pages, in the application or Emacs scrollback."
  (interactive "p")
  (if (mx-machina-eat--fullscreen-p)
      (mx-machina-eat--navigate 'next (or count 1))
    (eat-emacs-mode)
    (dotimes (_ (or count 1)) (scroll-up-command))))

(defun mx-machina-eat-latest ()
  "Return to the latest output and allow read acknowledgment again."
  (interactive)
  (when (mx-machina-eat--fullscreen-p)
    (mx-machina-eat--navigate 'C-end 1))
  (setq mx-machina-eat--browsing nil)
  (goto-char (if eat-terminal (eat-term-display-cursor eat-terminal) (point-max)))
  (recenter -1))

(defun mx-machina-eat-oldest ()
  "Show the beginning of the application's history or terminal scrollback."
  (interactive)
  (if (mx-machina-eat--fullscreen-p)
      (progn
        (setq mx-machina-eat--browsing t)
        (mx-machina-eat--navigate 'C-home 1))
    (eat-emacs-mode)
    (goto-char (point-min))))

(defun mx-machina-eat-wheel (event)
  "Route wheel EVENT to the application or ordinary Emacs scrollback."
  (interactive "e")
  (let ((window (posn-window (event-start event))))
    (when (window-live-p window)
      (with-selected-window window
        (if (mx-machina-eat--fullscreen-p)
            (progn
              (setq mx-machina-eat--browsing t)
              (goto-char (eat-term-display-cursor eat-terminal))
              (eat-term-input-event eat-terminal 1 event
                                   (posn-at-point (eat-term-display-beginning eat-terminal))))
          (eat-emacs-mode)
          (mwheel-scroll event))))))

(defvar mx-machina-eat-navigation-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding '(("<prior>" . mx-machina-eat-scroll-up)
                       ("<next>" . mx-machina-eat-scroll-down)
                       ("C-<home>" . mx-machina-eat-oldest)
                       ("C-<end>" . mx-machina-eat-latest)
                       ("C-c C-b" . mx-machina-eat-latest)
                       ("C-c ?" . mx-machina-actions)
                       ("<wheel-up>" . mx-machina-eat-wheel)
                       ("<wheel-down>" . mx-machina-eat-wheel)
                       ("<mouse-4>" . mx-machina-eat-wheel)
                       ("<mouse-5>" . mx-machina-eat-wheel)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map))

(defvar mx-machina-eat--navigation-maps
  `((mx-machina-eat--evil-scrolling
     . ,(let ((map (make-sparse-keymap)))
          (define-key map (kbd "C-u") #'mx-machina-eat-scroll-up)
          (define-key map (kbd "C-d") #'mx-machina-eat-scroll-down)
          map))
    (mx-machina-eat-navigation-mode . ,mx-machina-eat-navigation-mode-map)))

(define-minor-mode mx-machina-eat-navigation-mode
  "Route managed terminal scrolling to the owner of the conversation history."
  :lighter (:eval (when mx-machina-eat--browsing " History:C-c C-b"))
  ;; Precede both Evil and EAT's mouse/input maps, only in this buffer.
  (setq-local emulation-mode-map-alists
              (delq 'mx-machina-eat--navigation-maps
                    (copy-sequence emulation-mode-map-alists)))
  (when mx-machina-eat-navigation-mode
    (push 'mx-machina-eat--navigation-maps emulation-mode-map-alists))
  (unless mx-machina-eat-navigation-mode
    (setq mx-machina-eat--evil-scrolling nil)))

(defun mx-machina-eat-configs ()
  "Return configured EAT profiles without starting anything."
  (mapcar (lambda (config)
            (let ((copy (copy-tree config)))
              (unless (map-elt copy :agent) (setf (alist-get :agent copy) "Claude"))
              (unless (map-elt copy :account)
                (setf (alist-get :account copy) (symbol-name (map-elt copy :identifier))))
              copy))
          mx-machina-eat-profiles))

(defun mx-machina-eat-send-escape ()
  "Send Escape to Claude without leaving Evil insert state."
  (interactive)
  (eat-term-send-string eat-terminal "\e")
  ;; Claude has no Stop hook for a user interrupt.  Do not claim it finished.
  (when mx-machina-claude--turn-active
    (funcall (mx-machina-transport-callback mx-machina-claude--transport)
             "live" "unknown")))

(defun mx-machina-eat--read-position ()
  "Return the terminal cursor, excluding unused rows below the prompt."
  ;; In fullscreen the prompt stays visible even while reading old messages.
  (unless mx-machina-eat--browsing
    (if eat-terminal (eat-term-display-cursor eat-terminal) (point-max))))

(defun mx-machina-eat-sync-evil-state ()
  "Use Emacs navigation in Evil normal/visual states, terminal input in insert."
  (when (and (eq mx-machina--backend-kind 'eat) eat-terminal)
    (setq mx-machina-eat--evil-scrolling
          (and mx-machina-eat-navigation-mode (memq evil-state '(normal motion))))
    (if (memq evil-state '(insert emacs))
        (progn
          (eat-semi-char-mode)
          (goto-char (eat-term-display-cursor eat-terminal)))
      (eat-emacs-mode))))

(defun mx-machina-eat-setup-evil ()
  "Install buffer-local Evil state integration for a managed EAT buffer."
  (when (bound-and-true-p evil-local-mode)
    (dolist (hook '(evil-normal-state-entry-hook evil-visual-state-entry-hook
                    evil-insert-state-entry-hook evil-emacs-state-entry-hook
                    evil-motion-state-entry-hook evil-operator-state-entry-hook))
      (add-hook hook #'mx-machina-eat-sync-evil-state nil t))
    (mx-machina-eat-sync-evil-state)))

(defun mx-machina-eat--launch (command prepare)
  "Launch COMMAND in EAT, calling PREPARE after setting the major mode."
  (let ((eat-kill-buffer-on-exit nil)
        (eat-query-before-killing-running-terminal nil))
    (eat-mode)
    (funcall prepare)
    (setq-local eat-term-scrollback-size mx-machina-eat-scrollback-size
                mx-machina--read-position-function #'mx-machina-eat--read-position)
    (mx-machina-eat-navigation-mode 1)
    (use-local-map (copy-keymap (current-local-map)))
    (local-set-key (kbd "C-<escape>") #'mx-machina-eat-send-escape)
    (local-set-key (kbd "C-c C-t") #'mx-machina-transcript)
    (add-hook 'eat-exit-hook #'mx-machina-claude--exited nil t)
    (eat-exec (current-buffer) (buffer-name) (car command) nil (cdr command))))

(defun mx-machina-eat-start (profile directory conversation callback)
  "Start Claude PROFILE in EAT in DIRECTORY, restoring CONVERSATION.
Report lifecycle observations to CALLBACK."
  (unless (require 'eat nil t) (user-error "Install EAT to use a Claude terminal profile"))
  (mx-machina-claude-start
   profile (seq-find (lambda (entry) (equal profile (symbol-name (map-elt entry :identifier))))
                     mx-machina-eat-profiles)
   directory conversation callback 'eat #'mx-machina-eat--launch 'mx-machina-eat-setup-hook))

;; Existing runs can hold these function symbols in timers/hooks during reload.
(defalias 'mx-machina-eat--poll #'mx-machina-claude--poll)
(defalias 'mx-machina-eat--cancel-timer #'mx-machina-claude--cancel-timer)
(defalias 'mx-machina-eat--exited #'mx-machina-claude--exited)
(defalias 'mx-machina-eat-stop #'mx-machina-claude-stop)
(defalias 'mx-machina-eat-metadata #'mx-machina-claude-metadata)

(provide 'mx-machina-eat)
;;; mx-machina-eat.el ends here
