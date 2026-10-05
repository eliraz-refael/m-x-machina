;;; mx-machina-vterm.el --- Claude Code in vterm -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Vterm owns rendering; the shared Claude bridge owns identity and status.
;;; Code:
(require 'mwheel)
(require 'mx-machina-claude)
(defvar mx-machina-eat-profiles)
(declare-function mx-machina-eat-configs "mx-machina-eat")
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
(autoload 'mx-machina-transcript "mx-machina-transcript" nil t)

(defcustom mx-machina-vterm-profiles 'inherit
  "Claude profiles offered through vterm.
The default `inherit' shares EAT profiles' commands and accounts, with
identifiers suffixed by -vterm.  Alternatively supply profile alists, or nil
to hide vterm.  Existing EAT profile identifiers are never changed."
  :type '(choice (const inherit) (repeat alist)) :group 'mx-machina)
(defvar mx-machina-vterm-setup-hook nil)
(defvar-local mx-machina-vterm--browsing nil)
(defvar-local mx-machina-vterm--evil-scrolling nil)

(defun mx-machina-vterm-configs ()
  "Return vterm profiles without loading the native module or launching agents."
  (if (eq mx-machina-vterm-profiles 'inherit)
      (mapcar (lambda (config)
                (let ((copy (copy-tree config)))
                  (setf (alist-get :identifier copy)
                        (intern (concat (symbol-name (map-elt config :identifier)) "-vterm")))
                  copy))
              (mx-machina-eat-configs))
    (copy-tree mx-machina-vterm-profiles)))

(defun mx-machina-vterm--read-position ()
  "Return the prompt position only when following current output."
  (unless (or mx-machina-vterm--browsing vterm-copy-mode)
    (save-excursion (vterm-reset-cursor-point) (point))))

(defun mx-machina-vterm--navigate (key &optional control)
  "Send navigation KEY with optional CONTROL modifier to Claude."
  (when vterm-copy-mode (vterm-copy-mode -1))
  (vterm-send-key key nil nil control))

(defun mx-machina-vterm-scroll-up ()
  "Read older messages in Claude's fullscreen history."
  (interactive)
  (if vterm-copy-mode
      (scroll-down-command)
    (setq mx-machina-vterm--browsing t)
    (mx-machina-vterm--navigate "<prior>")))
(defun mx-machina-vterm-scroll-down ()
  "Read newer messages in Claude's fullscreen history."
  (interactive)
  (if vterm-copy-mode (scroll-up-command)
    (mx-machina-vterm--navigate "<next>")))
(defun mx-machina-vterm-latest ()
  "Resume following current output and allow read acknowledgment."
  (interactive)
  (mx-machina-vterm--navigate "<end>" t)
  (setq mx-machina-vterm--browsing nil))
(defun mx-machina-vterm-wheel (event)
  "Send a page navigation for wheel EVENT in its target terminal."
  (interactive "e")
  (let ((window (posn-window (event-start event))))
    (when (window-live-p window)
      (with-selected-window window
        (if vterm-copy-mode
            (mwheel-scroll event)
          (if (memq (event-basic-type event) '(wheel-up mouse-4))
              (mx-machina-vterm-scroll-up)
            (mx-machina-vterm-scroll-down)))))))
(defun mx-machina-vterm-send-escape ()
  "Send Escape to Claude while leaving Evil state unchanged."
  (interactive)
  (mx-machina-vterm--navigate "<escape>")
  (when mx-machina-claude--turn-active
    (funcall (mx-machina-transport-callback mx-machina-claude--transport)
             "live" "unknown")))

(defvar mx-machina-vterm-navigation-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding '(("<prior>" . mx-machina-vterm-scroll-up)
                       ("<next>" . mx-machina-vterm-scroll-down)
                       ("<wheel-up>" . mx-machina-vterm-wheel)
                       ("<wheel-down>" . mx-machina-vterm-wheel)
                       ("<mouse-4>" . mx-machina-vterm-wheel)
                       ("<mouse-5>" . mx-machina-vterm-wheel)
                       ("C-<end>" . mx-machina-vterm-latest)
                       ("C-c C-b" . mx-machina-vterm-latest)
                       ("C-c ?" . mx-machina-actions)
                       ("C-c C-t" . mx-machina-transcript)
                       ("C-c C-r" . vterm-copy-mode)
                       ("C-<escape>" . mx-machina-vterm-send-escape)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map))
(defvar mx-machina-vterm--navigation-maps
  `((mx-machina-vterm--evil-scrolling
     . ,(let ((map (make-sparse-keymap)))
          (define-key map (kbd "C-u") #'mx-machina-vterm-scroll-up)
          (define-key map (kbd "C-d") #'mx-machina-vterm-scroll-down)
          map))
    (mx-machina-vterm-navigation-mode . ,mx-machina-vterm-navigation-mode-map)))
(define-minor-mode mx-machina-vterm-navigation-mode
  "Provide managed Claude navigation independently of vterm and Evil maps."
  :lighter (:eval (when mx-machina-vterm--browsing " History:C-c C-b"))
  (setq-local emulation-mode-map-alists
              (delq 'mx-machina-vterm--navigation-maps (copy-sequence emulation-mode-map-alists)))
  (when mx-machina-vterm-navigation-mode
    (push 'mx-machina-vterm--navigation-maps emulation-mode-map-alists)))

(defun mx-machina-vterm-sync-evil-state ()
  "Reserve scrolling chords in normal state and resume rendering in insert."
  (setq mx-machina-vterm--evil-scrolling (memq evil-state '(normal motion)))
  (when (and (memq evil-state '(insert emacs)) vterm-copy-mode) (vterm-copy-mode -1)))
(defun mx-machina-vterm-setup-evil ()
  "Install buffer-local Evil integration."
  (when (bound-and-true-p evil-local-mode)
    (dolist (hook '(evil-normal-state-entry-hook evil-visual-state-entry-hook
                    evil-insert-state-entry-hook evil-emacs-state-entry-hook
                    evil-motion-state-entry-hook evil-operator-state-entry-hook))
      (add-hook hook #'mx-machina-vterm-sync-evil-state nil t))
    (mx-machina-vterm-sync-evil-state)))

(defun mx-machina-vterm--exited (buffer _event)
  "Report the terminal exit in BUFFER to the shared bridge."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (processp vterm--process)
        (mx-machina-claude--exited vterm--process)))))

(defun mx-machina-vterm--launch (command prepare)
  "Launch COMMAND in vterm and call PREPARE after setting its major mode."
  (let ((exit-functions (cons #'mx-machina-vterm--exited vterm-exit-functions)))
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
                mx-machina--read-position-function #'mx-machina-vterm--read-position)
    ;; Upstream's sentinel reads buffer-local settings without selecting it.
    (let* ((process (get-buffer-process (current-buffer)))
           (sentinel (process-sentinel process)))
      (set-process-sentinel process
                            (lambda (proc event)
                              (when (and (memq (process-status proc) '(exit signal))
                                         (buffer-live-p (process-buffer proc)))
                                (with-current-buffer (process-buffer proc)
                                  (funcall sentinel proc event))))))
    (mx-machina-vterm-navigation-mode 1)))

(defun mx-machina-vterm-start (profile directory conversation callback)
  "Start PROFILE in vterm in DIRECTORY, restoring CONVERSATION via CALLBACK."
  (unless (require 'vterm nil t) (user-error "Install vterm and its native module to use this interface"))
  (mx-machina-claude-start
   profile (seq-find (lambda (config) (equal profile (symbol-name (map-elt config :identifier))))
                     (mx-machina-vterm-configs))
   directory conversation callback 'vterm #'mx-machina-vterm--launch 'mx-machina-vterm-setup-hook))

(provide 'mx-machina-vterm)
;;; mx-machina-vterm.el ends here
