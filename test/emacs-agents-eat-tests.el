;;; emacs-agents-eat-tests.el --- Real terminal adapter tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'eat)
(require 'emacs-agents-recovery)

(unless (boundp 'emacs-agents-test-root)
  (load (expand-file-name "emacs-agents-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(defun emacs-agents-eat-test-wait (predicate)
  "Service terminal output and hooks until PREDICATE or a ten-second timeout."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall predicate))))

(defmacro emacs-agents-test-with-eat (&rest body)
  "Run BODY with EAT and an offline Claude CLI fixture."
  (declare (indent 0) (debug t))
  `(emacs-agents-test-with-store
     (let ((emacs-agents-eat-profiles
            (list (list (cons :identifier 'test-eat)
                        (cons :command (list "python3" (expand-file-name "test/fake-claude.py" emacs-agents-test-root)))
                        (cons :environment (list (concat "FAKE_CLAUDE_STORE=" (expand-file-name "claude" temporary))
                                                 "CLAUDE_CONFIG_DIR=fixture-account")))))
           (eat-kill-buffer-on-exit nil))
       ,@body)))

(defun emacs-agents-eat-test-screen-number (prefix)
  "Read the first numeric label with PREFIX in the current terminal."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward (concat prefix " \\([0-9]+\\)") nil t)
      (string-to-number (match-string 1)))))

(ert-deftest emacs-agents-eat-fullscreen-scroll-while-streaming ()
  (emacs-agents-test-with-eat
    (let* ((id (emacs-agents-create "Scrolling" repo "test-eat"))
           (buffer (emacs-agents-start id)))
      (emacs-agents-open id)
      (emacs-agents-eat-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
      (process-send-string (get-buffer-process buffer) "/fullscreen\n")
      (emacs-agents-eat-test-wait
       (lambda () (and (eat-term-in-alternative-display-p eat-terminal)
                       (emacs-agents-eat-test-screen-number "History row"))))
      (when (bound-and-true-p evil-mode) (evil-normal-state))
      (should (eq (key-binding (kbd "<prior>")) #'emacs-agents-eat-scroll-up))
      (should (eq (key-binding (kbd "<wheel-up>")) #'emacs-agents-eat-wheel))
      (when (bound-and-true-p evil-mode)
        (should (eq (key-binding (kbd "C-u")) #'emacs-agents-eat-scroll-up)))
      (let ((top (emacs-agents-eat-test-screen-number "History row")))
        (call-interactively (key-binding (kbd "<prior>")))
        (emacs-agents-eat-test-wait
         (lambda () (< (emacs-agents-eat-test-screen-number "History row") top))))
      (should-not (emacs-agents-eat--read-position))
      (let ((top (emacs-agents-eat-test-screen-number "History row"))
            (count (emacs-agents-eat-test-screen-number "STREAM COUNT")))
        (emacs-agents-eat-test-wait
         (lambda () (> (emacs-agents-eat-test-screen-number "STREAM COUNT") (+ count 2))))
        (should (= top (emacs-agents-eat-test-screen-number "History row")))
        (let ((event (list 'wheel-up (list (selected-window) (point-min) '(1 . 1) 0))))
          (emacs-agents-eat-wheel event))
        (emacs-agents-eat-test-wait
         (lambda () (< (emacs-agents-eat-test-screen-number "History row") top))))
      (emacs-agents-eat-oldest)
      (emacs-agents-eat-test-wait
       (lambda () (zerop (emacs-agents-eat-test-screen-number "History row"))))
      (when (bound-and-true-p evil-mode)
        (evil-insert-state)
        (should (eq (key-binding (kbd "<next>")) #'emacs-agents-eat-scroll-down))
        (should (eq (key-binding (kbd "<wheel-up>")) #'emacs-agents-eat-wheel))
        ;; Editing chords and ordinary text must still reach Claude.
        (should-not (eq (key-binding (kbd "C-u")) #'emacs-agents-eat-scroll-up))
        (should (eq (key-binding (kbd "RET")) #'eat-self-input)))
      (call-interactively (key-binding (kbd "<next>")))
      (emacs-agents-eat-test-wait
       (lambda () (> (emacs-agents-eat-test-screen-number "History row") 0)))
      (emacs-agents-eat-latest)
      (emacs-agents-eat-test-wait
       (lambda () (> (emacs-agents-eat-test-screen-number "History row") 60)))
      (should (emacs-agents-eat--read-position))
      (when (bound-and-true-p evil-mode)
        (evil-normal-state)
        (evil-visual-line)
        (should-not (eq (key-binding (kbd "C-u")) #'emacs-agents-eat-scroll-up))
        (evil-normal-state))
      (should (process-live-p (get-buffer-process buffer))))))

(ert-deftest emacs-agents-eat-classic-long-scrollback ()
  (emacs-agents-test-with-eat
    (let* ((id (emacs-agents-create "Long output" repo "test-eat"))
           (buffer (emacs-agents-start id)))
      (emacs-agents-open id)
      (emacs-agents-eat-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
      (process-send-string (get-buffer-process buffer) "/long\n")
      (emacs-agents-eat-test-wait
       (lambda () (string-match-p "Long row 3999" (buffer-string))))
      (should-not (eat-term-in-alternative-display-p eat-terminal))
      (should (> (buffer-size) 131072))
      (should (string-match-p "Long row 0000" (buffer-string)))
      (emacs-agents-eat-latest)
      (let ((position (point)))
        (emacs-agents-eat-scroll-up)
        (should (< (point) position)))
      (emacs-agents-eat-oldest)
      (should (= (point) (point-min)))
      (let ((position (point)))
        (process-send-string (get-buffer-process buffer) "More output\n")
        (emacs-agents-eat-test-wait
         (lambda () (string-match-p "Terminal reply 1" (buffer-string))))
        (should (= position (point)))))))

(ert-deftest emacs-agents-eat-working-approval-unread-and-resume ()
  (emacs-agents-test-with-eat
    (let* ((id (emacs-agents-create "Terminal" repo "test-eat"))
           (buffer (emacs-agents-start id)))
      (emacs-agents-eat-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
      (should (with-current-buffer buffer (derived-mode-p 'eat-mode)))
      (should (equal (emacs-agents-session-model (emacs-agents-session id)) "offline-terminal-model"))
      (should-not (emacs-agents-unread-p (emacs-agents-session id)))
      (should-not (kill-buffer buffer))
      (process-send-string (get-buffer-process buffer) "/work 0.7\n")
      (emacs-agents-eat-test-wait
       (lambda () (equal (emacs-agents-session-activity (emacs-agents-session id)) "working")))
      (emacs-agents-eat-test-wait
       (lambda () (and (emacs-agents-unread-p (emacs-agents-session id))
                       (equal (emacs-agents-session-activity (emacs-agents-session id)) "input"))))
      (should (equal (emacs-agents-session-activity (emacs-agents-session id)) "input"))
      (emacs-agents-mark-read id)
      (process-send-string (get-buffer-process buffer) "/ask\n")
      (emacs-agents-eat-test-wait
       (lambda () (equal (emacs-agents-session-activity (emacs-agents-session id)) "approval")))
      (should-not (emacs-agents-unread-p (emacs-agents-session id)))
      (process-send-string (get-buffer-process buffer) "/approve\n")
      (emacs-agents-eat-test-wait
       (lambda () (and (emacs-agents-unread-p (emacs-agents-session id))
                       (equal (emacs-agents-session-activity (emacs-agents-session id)) "input"))))
      (let ((sid (emacs-agents-session-conversation (emacs-agents-session id))))
        (let ((directory (buffer-local-value 'emacs-agents-claude--run-directory buffer)))
          (should (file-directory-p directory))
          (emacs-agents-stop id)
          (should-not (file-exists-p directory)))
        (should-not (buffer-local-value 'emacs-agents-claude--timer buffer))
        (emacs-agents-mark-read id)
        (emacs-agents-store-close)
        (setq buffer (emacs-agents-start id))
        (emacs-agents-eat-test-wait
         (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
        (should (equal (emacs-agents-session-conversation (emacs-agents-session id)) sid))
        (should-not (emacs-agents-unread-p (emacs-agents-session id)))
        (process-send-string (get-buffer-process buffer) "Again\n")
        (emacs-agents-eat-test-wait
         (lambda () (with-current-buffer buffer (string-match-p "Terminal reply 3" (buffer-string)))))))))

(ert-deftest emacs-agents-eat-archive-restore-resume-and-delete-running ()
  (emacs-agents-test-with-eat
    (let* ((id (emacs-agents-create "Archive me" repo "test-eat"))
           (buffer (emacs-agents-start id)))
      (unwind-protect
          (progn
            (emacs-agents-eat-test-wait
             (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
            (let* ((sid (emacs-agents-session-conversation (emacs-agents-session id)))
                   (process (get-buffer-process buffer))
                   (history (expand-file-name (concat "claude/" sid ".json") temporary)))
              (should-error (emacs-agents-archive id) :type 'user-error)
              (should (process-live-p process))
              (emacs-agents-archive id t)
              (should-not (process-live-p process))
              (should-not (gethash id emacs-agents--running))
              (emacs-agents-restore id)
              (should-not (gethash id emacs-agents--running))
              (setq buffer (emacs-agents-start id))
              (emacs-agents-eat-test-wait
               (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
              (should (equal sid (emacs-agents-session-conversation (emacs-agents-session id))))
              (setq process (get-buffer-process buffer))
              (emacs-agents-delete id t)
              (should-not (process-live-p process))
              (should-not (gethash id emacs-agents--running))
              (should-not (buffer-local-value 'emacs-agents-claude--timer buffer))
              (should (file-exists-p history))
              (should (file-directory-p repo))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest emacs-agents-eat-replacement-stops-with-original-id ()
  (emacs-agents-test-with-eat
    (let* ((id (emacs-agents-create "Terminal" repo "test-eat"))
           (buffer (emacs-agents-start id))
           (sid (emacs-agents-session-conversation (emacs-agents-session id))))
      (emacs-agents-eat-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
      (process-send-string (get-buffer-process buffer) "/replace\n")
      (emacs-agents-eat-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "failed")))
      (emacs-agents-eat-test-wait (lambda () (not (get-buffer-process buffer))))
      (should (equal (emacs-agents-session-conversation (emacs-agents-session id)) sid))
      (should-not (buffer-local-value 'emacs-agents-claude--timer buffer)))))

(ert-deftest emacs-agents-eat-missing-history-does-not-fall-back ()
  (emacs-agents-test-with-eat
    (let* ((id (emacs-agents-create "Missing" repo "test-eat"))
           (run (emacs-agents--begin-run id)))
      (emacs-agents--observe id run "stopped" "unknown" "missing-saved-id")
      (emacs-agents-start id)
      (emacs-agents-eat-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "failed")))
      (should (equal (emacs-agents-session-conversation (emacs-agents-session id)) "missing-saved-id"))
      (with-temp-buffer
        (insert-file-contents (expand-file-name "claude/launches.jsonl" temporary))
        (let ((request (json-parse-string (buffer-string) :object-type 'alist :null-object nil)))
          (should-not (alist-get 'new request))
          (should (equal (alist-get 'resume request) "missing-saved-id")))))))

(ert-deftest emacs-agents-eat-layout-keys-redraw-and-process-exit ()
  (emacs-agents-test-with-eat
    (let* ((id (emacs-agents-create "Terminal" repo "test-eat"))
           (buffer (emacs-agents-start id)))
      (emacs-agents-eat-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
      (emacs-agents)
      (emacs-agents-open id)
      (should (= (length (window-list)) 2))
      (should (eq (current-buffer) buffer))
      (should (eq (key-binding (kbd "C-c C-q")) #'emacs-agents-close-view))
      (should (eq (key-binding (kbd "C-c C-z")) #'emacs-agents-focus))
      (should (eq (key-binding (kbd "C-<escape>")) #'emacs-agents-eat-send-escape))
      (when (bound-and-true-p evil-mode)
        (evil-normal-state)
        (should (eq (key-binding (kbd "q")) #'emacs-agents-close-view))
        (evil-insert-state)
        (should (eq (key-binding (kbd "RET")) #'eat-self-input))
        (should (eq (key-binding (kbd "C-<escape>")) #'emacs-agents-eat-send-escape)))
      (should (string-match-p "Terminal" emacs-agents--identity))
      (emacs-agents-focus id)
      (should (= (length (window-list)) 1))
      (emacs-agents-close-view)
      (should (process-live-p (get-buffer-process buffer)))
      (process-send-string (get-buffer-process buffer) "/redraw\n/model\n")
      (emacs-agents-eat-test-wait
       (lambda () (equal (emacs-agents-session-model (emacs-agents-session id)) "offline-terminal-model-2")))
      (should-not (emacs-agents-unread-p (emacs-agents-session id)))
      (let ((directory (buffer-local-value 'emacs-agents-claude--run-directory buffer)))
        (process-send-string (get-buffer-process buffer) "/exit\n")
        (emacs-agents-eat-test-wait
         (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "exited")))
        (should-not (file-exists-p directory)))
      (should (buffer-live-p buffer))
      (should-not (buffer-local-value 'emacs-agents-claude--timer buffer)))))

(ert-deftest emacs-agents-eat-partial-events-and-late-events ()
  (emacs-agents-test-with-eat
    (let* ((id (emacs-agents-create "Terminal" repo "test-eat"))
           (buffer (emacs-agents-start id)))
      (emacs-agents-eat-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
      (with-current-buffer buffer
        (let ((event (json-encode `((hook_event_name . "UserPromptSubmit")
                                     (session_id . ,(emacs-agents-session-conversation (emacs-agents-session id))))))
              (offset emacs-agents-claude--offset))
          (write-region event nil emacs-agents-claude--event-file t 'silent)
          (emacs-agents-claude--poll buffer)
          (should (= offset emacs-agents-claude--offset))
          (should (equal (emacs-agents-session-activity (emacs-agents-session id)) "input"))
          (write-region "\n" nil emacs-agents-claude--event-file t 'silent)
          (emacs-agents-claude--poll buffer)
          (should (equal (emacs-agents-session-activity (emacs-agents-session id)) "working"))
          (emacs-agents-stop id)
          (emacs-agents-claude--event (json-parse-string event :object-type 'alist))
          (should (equal (emacs-agents-session-status (emacs-agents-session id)) "stopped")))))))

(ert-deftest emacs-agents-eat-profiles-isolate-accounts-and-worktrees ()
  (emacs-agents-test-with-eat
    (let* ((second-store (expand-file-name "other-account" temporary))
           (other (expand-file-name "other-worktree" temporary))
           (second-config (copy-tree (car emacs-agents-eat-profiles)))
           (outer-env (getenv "CLAUDE_CONFIG_DIR")))
      (setf (alist-get :identifier second-config) 'second-eat
            (alist-get :environment second-config)
            (list (concat "FAKE_CLAUDE_STORE=" second-store) "CLAUDE_CONFIG_DIR=other-account"))
      (push second-config emacs-agents-eat-profiles)
      (emacs-agents--git repo "worktree" "add" "-b" "other" other)
      (let ((first (emacs-agents-create "First" repo "test-eat"))
            (second (emacs-agents-create "Second" other "second-eat")))
        (emacs-agents-start first)
        (emacs-agents-start second)
        (emacs-agents-eat-test-wait
         (lambda () (seq-every-p
                     (lambda (id) (equal (emacs-agents-session-status (emacs-agents-session id)) "live"))
                     (list first second))))
        (should (equal outer-env (getenv "CLAUDE_CONFIG_DIR")))
        (dolist (entry (list (list "claude" "fixture-account" repo)
                             (list "other-account" "other-account" other)))
          (with-temp-buffer
            (insert-file-contents (expand-file-name (concat (car entry) "/launches.jsonl") temporary))
            (let ((request (json-parse-string (buffer-string) :object-type 'alist)))
              (should (equal (alist-get 'account request) (cadr entry)))
              (should (equal (file-truename (alist-get 'cwd request))
                             (directory-file-name (file-truename (caddr entry))))))))))))

(ert-deftest emacs-agents-eat-setup-failure-releases-process-timer-and-files ()
  (emacs-agents-test-with-eat
    (let ((id (emacs-agents-create "Broken setup" repo "test-eat")) buffer directory)
      (unwind-protect
          (let ((emacs-agents-eat-setup-hook
                 (list (lambda ()
                         (setq buffer (current-buffer) directory emacs-agents-claude--run-directory)
                         (error "Intentional setup failure")))))
            (should-error (emacs-agents-start id))
            (should (equal (emacs-agents-session-status (emacs-agents-session id)) "failed"))
            (should-not (gethash id emacs-agents--running))
            (should-not (get-buffer-process buffer))
            (should-not (buffer-local-value 'emacs-agents-claude--timer buffer))
            (should-not (file-exists-p directory)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest emacs-agents-eat-recovery-resumes-original-account-and-id ()
  (emacs-agents-test-with-eat
    (let* ((id (emacs-agents-create "Relocated terminal" repo "test-eat"))
           (new (expand-file-name "relocated" temporary)))
      (emacs-agents-start id)
      (emacs-agents-eat-test-wait
       (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
      (let ((sid (emacs-agents-session-conversation (emacs-agents-session id))))
        (emacs-agents-stop id)
        (rename-file repo new)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (emacs-agents-rebind-worktree id new))
        (emacs-agents-start id)
        (emacs-agents-eat-test-wait
         (lambda () (equal (emacs-agents-session-status (emacs-agents-session id)) "live")))
        (should (equal sid (emacs-agents-session-conversation (emacs-agents-session id))))
        (with-temp-buffer
          (insert-file-contents (expand-file-name "claude/launches.jsonl" temporary))
          (let* ((rows (mapcar (lambda (line) (json-parse-string line :object-type 'alist))
                               (split-string (buffer-string) "\n" t)))
                 (resume (nth 1 rows)))
            (should (= 2 (length rows)))
            (should (equal (alist-get 'resume resume) sid))
            (should (eq (alist-get 'new resume) :null))
            (should (equal (alist-get 'account resume) "fixture-account"))
            (should (file-equal-p (alist-get 'cwd resume) new))))))))
;;; emacs-agents-eat-tests.el ends here
