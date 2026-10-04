;;; emacs-agents-vterm.el --- Claude Code in vterm -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Vterm owns rendering; the shared Claude bridge owns identity and status.
;;; Code:
(require 'emacs-agents-claude)
(defvar emacs-agents-eat-profiles)
(declare-function emacs-agents-eat-configs "emacs-agents-eat")
(defvar evil-state)
(defvar vterm-shell)
(defvar vterm-environment)
(defvar vterm-mode-hook)
(defvar vterm-kill-buffer-on-exit)
(defvar vterm-exit-functions)
(defvar vterm-max-scrollback)
(defvar vterm-copy-mode)
(defvar vterm--process)
(declare-function vterm-mode "vterm")
(declare-function vterm-send-key "vterm")
(declare-function vterm-reset-cursor-point "vterm")
(declare-function vterm-copy-mode "vterm")
(autoload 'emacs-agents-transcript "emacs-agents-transcript" nil t)

(defcustom emacs-agents-vterm-profiles 'inherit
  "Claude profiles offered through vterm.
The default `inherit' shares EAT profiles' commands and accounts, with
identifiers suffixed by -vterm.  Alternatively supply profile alists, or nil
to hide vterm.  Existing EAT profile identifiers are never changed."
  :type '(choice (const inherit) (repeat alist)) :group 'emacs-agents)
(defvar emacs-agents-vterm-setup-hook nil)
(defvar-local emacs-agents-vterm--browsing nil)
(defvar-local emacs-agents-vterm--evil-scrolling nil)

(defun emacs-agents-vterm-configs ()
  "Return vterm profiles without loading the native module or launching agents."
  (if (eq emacs-agents-vterm-profiles 'inherit)
      (mapcar (lambda (config)
                (let ((copy (copy-tree config)))
                  (setf (alist-get :identifier copy)
                        (intern (concat (symbol-name (map-elt config :identifier)) "-vterm")))
                  copy))
              (emacs-agents-eat-configs))
    (copy-tree emacs-agents-vterm-profiles)))

(defun emacs-agents-vterm--read-position ()
  "Return the prompt position only when following current output."
  (unless (or emacs-agents-vterm--browsing vterm-copy-mode)
    (save-excursion (vterm-reset-cursor-point) (point))))

(defun emacs-agents-vterm--navigate (key &optional control)
  "Send navigation KEY with optional CONTROL modifier to Claude."
  (when vterm-copy-mode (vterm-copy-mode -1))
  (vterm-send-key key nil nil control))

(defun emacs-agents-vterm-scroll-up ()
  "Read older messages in Claude's fullscreen history."
  (interactive)
  (if vterm-copy-mode
      (scroll-down-command)
    (setq emacs-agents-vterm--browsing t)
    (emacs-agents-vterm--navigate "<prior>")))
(defun emacs-agents-vterm-scroll-down ()
  "Read newer messages in Claude's fullscreen history."
  (interactive)
  (if vterm-copy-mode (scroll-up-command)
    (emacs-agents-vterm--navigate "<next>")))
(defun emacs-agents-vterm-latest ()
  "Resume following current output and allow read acknowledgment."
  (interactive)
  (emacs-agents-vterm--navigate "<end>" t)
  (setq emacs-agents-vterm--browsing nil))
(defun emacs-agents-vterm-wheel (event)
  "Send a page navigation for wheel EVENT in its target terminal."
  (interactive "e")
  (let ((window (posn-window (event-start event))))
    (when (window-live-p window)
      (with-selected-window window
        (if vterm-copy-mode
            (mwheel-scroll event)
          (if (memq (event-basic-type event) '(wheel-up mouse-4))
              (emacs-agents-vterm-scroll-up)
            (emacs-agents-vterm-scroll-down)))))))
(defun emacs-agents-vterm-send-escape ()
  "Send Escape to Claude while leaving Evil state unchanged."
  (interactive)
  (emacs-agents-vterm--navigate "<escape>")
  (when emacs-agents-claude--turn-active
    (funcall (emacs-agents-transport-callback emacs-agents-claude--transport)
             "live" "unknown")))

(defvar emacs-agents-vterm-navigation-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding '(("<prior>" . emacs-agents-vterm-scroll-up)
                       ("<next>" . emacs-agents-vterm-scroll-down)
                       ("<wheel-up>" . emacs-agents-vterm-wheel)
                       ("<wheel-down>" . emacs-agents-vterm-wheel)
                       ("<mouse-4>" . emacs-agents-vterm-wheel)
                       ("<mouse-5>" . emacs-agents-vterm-wheel)
                       ("C-<end>" . emacs-agents-vterm-latest)
                       ("C-c C-b" . emacs-agents-vterm-latest)
                       ("C-c ?" . emacs-agents-actions)
                       ("C-c C-t" . emacs-agents-transcript)
                       ("C-c C-r" . vterm-copy-mode)
                       ("C-<escape>" . emacs-agents-vterm-send-escape)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map))
(defvar emacs-agents-vterm--navigation-maps
  `((emacs-agents-vterm--evil-scrolling
     . ,(let ((map (make-sparse-keymap)))
          (define-key map (kbd "C-u") #'emacs-agents-vterm-scroll-up)
          (define-key map (kbd "C-d") #'emacs-agents-vterm-scroll-down)
          map))
    (emacs-agents-vterm-navigation-mode . ,emacs-agents-vterm-navigation-mode-map)))
(define-minor-mode emacs-agents-vterm-navigation-mode
  "Provide managed Claude navigation independently of vterm and Evil maps."
  :lighter (:eval (when emacs-agents-vterm--browsing " History:C-c C-b"))
  (setq-local emulation-mode-map-alists
              (delq 'emacs-agents-vterm--navigation-maps (copy-sequence emulation-mode-map-alists)))
  (when emacs-agents-vterm-navigation-mode
    (push 'emacs-agents-vterm--navigation-maps emulation-mode-map-alists)))

(defun emacs-agents-vterm-sync-evil-state ()
  "Reserve scrolling chords in normal state and resume rendering in insert."
  (setq emacs-agents-vterm--evil-scrolling (memq evil-state '(normal motion)))
  (when (and (memq evil-state '(insert emacs)) vterm-copy-mode) (vterm-copy-mode -1)))
(defun emacs-agents-vterm-setup-evil ()
  "Install buffer-local Evil integration."
  (when (bound-and-true-p evil-local-mode)
    (dolist (hook '(evil-normal-state-entry-hook evil-visual-state-entry-hook
                    evil-insert-state-entry-hook evil-emacs-state-entry-hook
                    evil-motion-state-entry-hook evil-operator-state-entry-hook))
      (add-hook hook #'emacs-agents-vterm-sync-evil-state nil t))
    (emacs-agents-vterm-sync-evil-state)))

(defun emacs-agents-vterm--exited (buffer _event)
  "Report the terminal exit in BUFFER to the shared bridge."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (processp vterm--process)
        (emacs-agents-claude--exited vterm--process)))))

(defun emacs-agents-vterm--launch (command prepare)
  "Launch COMMAND in vterm and call PREPARE after setting its major mode."
  (let ((exit-functions (cons #'emacs-agents-vterm--exited vterm-exit-functions)))
    (let ((vterm-shell (mapconcat #'shell-quote-argument command " "))
          (vterm-environment nil)
          (vterm-max-scrollback 10000)
          (vterm-kill-buffer-on-exit nil)
          (vterm-exit-functions exit-functions)
          (vterm-mode-hook (cons prepare vterm-mode-hook))
          ;; An agent profile, not project-local shell settings, chooses the CLI.
          (enable-local-variables nil))
      (vterm-mode))
    (setq-local vterm-kill-buffer-on-exit nil
                vterm-exit-functions exit-functions
                emacs-agents--read-position-function #'emacs-agents-vterm--read-position)
    ;; Upstream's sentinel reads buffer-local settings without selecting it.
    (let* ((process (get-buffer-process (current-buffer)))
           (sentinel (process-sentinel process)))
      (set-process-sentinel process
                            (lambda (proc event)
                              (when (and (memq (process-status proc) '(exit signal))
                                         (buffer-live-p (process-buffer proc)))
                                (with-current-buffer (process-buffer proc)
                                  (funcall sentinel proc event))))))
    (emacs-agents-vterm-navigation-mode 1)))

(defun emacs-agents-vterm-start (profile directory conversation callback)
  "Start PROFILE in vterm in DIRECTORY, restoring CONVERSATION via CALLBACK."
  (unless (require 'vterm nil t) (user-error "Install vterm and its native module to use this interface"))
  (emacs-agents-claude-start
   profile (seq-find (lambda (config) (equal profile (symbol-name (map-elt config :identifier))))
                     (emacs-agents-vterm-configs))
   directory conversation callback 'vterm #'emacs-agents-vterm--launch 'emacs-agents-vterm-setup-hook))

(provide 'emacs-agents-vterm)
;;; emacs-agents-vterm.el ends here
