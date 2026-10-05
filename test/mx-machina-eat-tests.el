;;; mx-machina-eat-tests.el --- Real terminal adapter tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'eat)
(require 'mx-machina-recovery)

(unless (boundp 'mx-machina-test-root)
  (load (expand-file-name "mx-machina-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(defun mx-machina-eat-test-wait (predicate)
  "Service terminal output and hooks until PREDICATE or a ten-second timeout."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall predicate))))

(defmacro mx-machina-test-with-eat (&rest body)
  "Run BODY with EAT and an offline Claude CLI fixture."
  (declare (indent 0) (debug t))
  `(mx-machina-test-with-store
     (let ((mx-machina-eat-profiles
            (list (list (cons :identifier 'test-eat)
                        (cons :command (list "python3" (expand-file-name "test/fake-claude.py" mx-machina-test-root)))
                        (cons :environment (list (concat "FAKE_CLAUDE_STORE=" (expand-file-name "claude" temporary))
                                                 "CLAUDE_CONFIG_DIR=fixture-account")))))
           (eat-kill-buffer-on-exit nil))
       ,@body)))

(defun mx-machina-eat-test-screen-number (prefix)
  "Read the first numeric label with PREFIX in the current terminal."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward (concat prefix " \\([0-9]+\\)") nil t)
      (string-to-number (match-string 1)))))

(ert-deftest mx-machina-eat-fullscreen-scroll-while-streaming ()
  (mx-machina-test-with-eat
    (let* ((id (mx-machina-create "Scrolling" repo "test-eat"))
           (buffer (mx-machina-start id)))
      (mx-machina-open id)
      (mx-machina-eat-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (process-send-string (get-buffer-process buffer) "/fullscreen\n")
      (mx-machina-eat-test-wait
       (lambda () (and (eat-term-in-alternative-display-p eat-terminal)
                       (mx-machina-eat-test-screen-number "History row"))))
      (when (bound-and-true-p evil-mode) (evil-normal-state))
      (should (eq (key-binding (kbd "<prior>")) #'mx-machina-eat-scroll-up))
      (should (eq (key-binding (kbd "<wheel-up>")) #'mx-machina-eat-wheel))
      (when (bound-and-true-p evil-mode)
        (should (eq (key-binding (kbd "C-u")) #'mx-machina-eat-scroll-up)))
      (let ((top (mx-machina-eat-test-screen-number "History row")))
        (call-interactively (key-binding (kbd "<prior>")))
        (mx-machina-eat-test-wait
         (lambda () (< (mx-machina-eat-test-screen-number "History row") top))))
      (should-not (mx-machina-eat--read-position))
      (let ((top (mx-machina-eat-test-screen-number "History row"))
            (count (mx-machina-eat-test-screen-number "STREAM COUNT")))
        (mx-machina-eat-test-wait
         (lambda () (> (mx-machina-eat-test-screen-number "STREAM COUNT") (+ count 2))))
        (should (= top (mx-machina-eat-test-screen-number "History row")))
        (let ((event (list 'wheel-up (list (selected-window) (point-min) '(1 . 1) 0))))
          (mx-machina-eat-wheel event))
        (mx-machina-eat-test-wait
         (lambda () (< (mx-machina-eat-test-screen-number "History row") top))))
      (mx-machina-eat-oldest)
      (mx-machina-eat-test-wait
       (lambda () (zerop (mx-machina-eat-test-screen-number "History row"))))
      (when (bound-and-true-p evil-mode)
        (evil-insert-state)
        (should (eq (key-binding (kbd "<next>")) #'mx-machina-eat-scroll-down))
        (should (eq (key-binding (kbd "<wheel-up>")) #'mx-machina-eat-wheel))
        ;; Editing chords and ordinary text must still reach Claude.
        (should-not (eq (key-binding (kbd "C-u")) #'mx-machina-eat-scroll-up))
        (should (eq (key-binding (kbd "RET")) #'eat-self-input)))
      (call-interactively (key-binding (kbd "<next>")))
      (mx-machina-eat-test-wait
       (lambda () (> (mx-machina-eat-test-screen-number "History row") 0)))
      (mx-machina-eat-latest)
      (mx-machina-eat-test-wait
       (lambda () (> (mx-machina-eat-test-screen-number "History row") 60)))
      (should (mx-machina-eat--read-position))
      (when (bound-and-true-p evil-mode)
        (evil-normal-state)
        (evil-visual-line)
        (should-not (eq (key-binding (kbd "C-u")) #'mx-machina-eat-scroll-up))
        (evil-normal-state))
      (should (process-live-p (get-buffer-process buffer))))))

(ert-deftest mx-machina-eat-classic-long-scrollback ()
  (mx-machina-test-with-eat
    (let* ((id (mx-machina-create "Long output" repo "test-eat"))
           (buffer (mx-machina-start id)))
      (mx-machina-open id)
      (mx-machina-eat-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (process-send-string (get-buffer-process buffer) "/long\n")
      (mx-machina-eat-test-wait
       (lambda () (string-match-p "Long row 3999" (buffer-string))))
      (should-not (eat-term-in-alternative-display-p eat-terminal))
      (should (> (buffer-size) 131072))
      (should (string-match-p "Long row 0000" (buffer-string)))
      (mx-machina-eat-latest)
      (let ((position (point)))
        (mx-machina-eat-scroll-up)
        (should (< (point) position)))
      (mx-machina-eat-oldest)
      (should (= (point) (point-min)))
      (let ((position (point)))
        (process-send-string (get-buffer-process buffer) "More output\n")
        (mx-machina-eat-test-wait
         (lambda () (string-match-p "Terminal reply 1" (buffer-string))))
        (should (= position (point)))))))

(ert-deftest mx-machina-eat-working-approval-unread-and-resume ()
  (mx-machina-test-with-eat
    (let* ((id (mx-machina-create "Terminal" repo "test-eat"))
           (buffer (mx-machina-start id)))
      (mx-machina-eat-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (should (with-current-buffer buffer (derived-mode-p 'eat-mode)))
      (should (equal (mx-machina-session-model (mx-machina-session id)) "offline-terminal-model"))
      (should-not (mx-machina-unread-p (mx-machina-session id)))
      (should-not (kill-buffer buffer))
      (process-send-string (get-buffer-process buffer) "/work 0.7\n")
      (mx-machina-eat-test-wait
       (lambda () (equal (mx-machina-session-activity (mx-machina-session id)) "working")))
      (mx-machina-eat-test-wait
       (lambda () (and (mx-machina-unread-p (mx-machina-session id))
                       (equal (mx-machina-session-activity (mx-machina-session id)) "input"))))
      (should (equal (mx-machina-session-activity (mx-machina-session id)) "input"))
      (mx-machina-mark-read id)
      (process-send-string (get-buffer-process buffer) "/ask\n")
      (mx-machina-eat-test-wait
       (lambda () (equal (mx-machina-session-activity (mx-machina-session id)) "approval")))
      (should-not (mx-machina-unread-p (mx-machina-session id)))
      (process-send-string (get-buffer-process buffer) "/approve\n")
      (mx-machina-eat-test-wait
       (lambda () (and (mx-machina-unread-p (mx-machina-session id))
                       (equal (mx-machina-session-activity (mx-machina-session id)) "input"))))
      (let ((sid (mx-machina-session-conversation (mx-machina-session id))))
        (let ((directory (buffer-local-value 'mx-machina-claude--run-directory buffer)))
          (should (file-directory-p directory))
          (mx-machina-stop id)
          (should-not (file-exists-p directory)))
        (should-not (buffer-local-value 'mx-machina-claude--timer buffer))
        (mx-machina-mark-read id)
        (mx-machina-store-close)
        (setq buffer (mx-machina-start id))
        (mx-machina-eat-test-wait
         (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
        (should (equal (mx-machina-session-conversation (mx-machina-session id)) sid))
        (should-not (mx-machina-unread-p (mx-machina-session id)))
        (process-send-string (get-buffer-process buffer) "Again\n")
        (mx-machina-eat-test-wait
         (lambda () (with-current-buffer buffer (string-match-p "Terminal reply 3" (buffer-string)))))))))

(ert-deftest mx-machina-eat-archive-restore-resume-and-delete-running ()
  (mx-machina-test-with-eat
    (let* ((id (mx-machina-create "Archive me" repo "test-eat"))
           (buffer (mx-machina-start id)))
      (unwind-protect
          (progn
            (mx-machina-eat-test-wait
             (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
            (let* ((sid (mx-machina-session-conversation (mx-machina-session id)))
                   (process (get-buffer-process buffer))
                   (history (expand-file-name (concat "claude/" sid ".json") temporary)))
              (should-error (mx-machina-archive id) :type 'user-error)
              (should (process-live-p process))
              (mx-machina-archive id t)
              (should-not (process-live-p process))
              (should-not (gethash id mx-machina--running))
              (mx-machina-restore id)
              (should-not (gethash id mx-machina--running))
              (setq buffer (mx-machina-start id))
              (mx-machina-eat-test-wait
               (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
              (should (equal sid (mx-machina-session-conversation (mx-machina-session id))))
              (setq process (get-buffer-process buffer))
              (mx-machina-delete id t)
              (should-not (process-live-p process))
              (should-not (gethash id mx-machina--running))
              (should-not (buffer-local-value 'mx-machina-claude--timer buffer))
              (should (file-exists-p history))
              (should (file-directory-p repo))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest mx-machina-eat-replacement-stops-with-original-id ()
  (mx-machina-test-with-eat
    (let* ((id (mx-machina-create "Terminal" repo "test-eat"))
           (buffer (mx-machina-start id))
           (sid (mx-machina-session-conversation (mx-machina-session id))))
      (mx-machina-eat-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (process-send-string (get-buffer-process buffer) "/replace\n")
      (mx-machina-eat-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "failed")))
      (mx-machina-eat-test-wait (lambda () (not (get-buffer-process buffer))))
      (should (equal (mx-machina-session-conversation (mx-machina-session id)) sid))
      (should-not (buffer-local-value 'mx-machina-claude--timer buffer)))))

(ert-deftest mx-machina-eat-missing-history-does-not-fall-back ()
  (mx-machina-test-with-eat
    (let* ((id (mx-machina-create "Missing" repo "test-eat"))
           (run (mx-machina--begin-run id)))
      (mx-machina--observe id run "stopped" "unknown" "missing-saved-id")
      (mx-machina-start id)
      (mx-machina-eat-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "failed")))
      (should (equal (mx-machina-session-conversation (mx-machina-session id)) "missing-saved-id"))
      (with-temp-buffer
        (insert-file-contents (expand-file-name "claude/launches.jsonl" temporary))
        (let ((request (json-parse-string (buffer-string) :object-type 'alist :null-object nil)))
          (should-not (alist-get 'new request))
          (should (equal (alist-get 'resume request) "missing-saved-id")))))))

(ert-deftest mx-machina-eat-layout-keys-redraw-and-process-exit ()
  (mx-machina-test-with-eat
    (let* ((id (mx-machina-create "Terminal" repo "test-eat"))
           (buffer (mx-machina-start id)))
      (mx-machina-eat-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (mx-machina)
      (mx-machina-open id)
      (should (= (length (window-list)) 2))
      (should (eq (current-buffer) buffer))
      (should (eq (key-binding (kbd "C-c C-q")) #'mx-machina-close-view))
      (should (eq (key-binding (kbd "C-c ?")) #'mx-machina-actions))
      (should (eq (key-binding (kbd "C-c C-z")) #'mx-machina-focus))
      (should (eq (key-binding (kbd "C-<escape>")) #'mx-machina-eat-send-escape))
      (when (bound-and-true-p evil-mode)
        (evil-normal-state)
        (should (eq (key-binding (kbd "q")) #'mx-machina-close-view))
        (evil-insert-state)
        (should (eq (key-binding (kbd "C-c ?")) #'mx-machina-actions))
        (should (eq (key-binding (kbd "RET")) #'eat-self-input))
        (should (eq (key-binding (kbd "C-<escape>")) #'mx-machina-eat-send-escape)))
      (should (string-match-p "Terminal" mx-machina--identity))
      (mx-machina-focus id)
      (should (= (length (window-list)) 1))
      (mx-machina-close-view)
      (should (process-live-p (get-buffer-process buffer)))
      (process-send-string (get-buffer-process buffer) "/redraw\n/model\n")
      (mx-machina-eat-test-wait
       (lambda () (equal (mx-machina-session-model (mx-machina-session id)) "offline-terminal-model-2")))
      (should-not (mx-machina-unread-p (mx-machina-session id)))
      (let ((directory (buffer-local-value 'mx-machina-claude--run-directory buffer)))
        (process-send-string (get-buffer-process buffer) "/exit\n")
        (mx-machina-eat-test-wait
         (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "exited")))
        (should-not (file-exists-p directory)))
      (should (buffer-live-p buffer))
      (should-not (buffer-local-value 'mx-machina-claude--timer buffer)))))

(ert-deftest mx-machina-eat-partial-events-and-late-events ()
  (mx-machina-test-with-eat
    (let* ((id (mx-machina-create "Terminal" repo "test-eat"))
           (buffer (mx-machina-start id)))
      (mx-machina-eat-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (with-current-buffer buffer
        (let ((event (json-encode `((hook_event_name . "UserPromptSubmit")
                                     (session_id . ,(mx-machina-session-conversation (mx-machina-session id))))))
              (offset mx-machina-claude--offset))
          (write-region event nil mx-machina-claude--event-file t 'silent)
          (mx-machina-claude--poll buffer)
          (should (= offset mx-machina-claude--offset))
          (should (equal (mx-machina-session-activity (mx-machina-session id)) "input"))
          (write-region "\n" nil mx-machina-claude--event-file t 'silent)
          (mx-machina-claude--poll buffer)
          (should (equal (mx-machina-session-activity (mx-machina-session id)) "working"))
          (mx-machina-stop id)
          (mx-machina-claude--event (json-parse-string event :object-type 'alist))
          (should (equal (mx-machina-session-status (mx-machina-session id)) "stopped")))))))

(ert-deftest mx-machina-eat-profiles-isolate-accounts-and-worktrees ()
  (mx-machina-test-with-eat
    (let* ((second-store (expand-file-name "other-account" temporary))
           (other (expand-file-name "other-worktree" temporary))
           (second-config (copy-tree (car mx-machina-eat-profiles)))
           (outer-env (getenv "CLAUDE_CONFIG_DIR")))
      (setf (alist-get :identifier second-config) 'second-eat
            (alist-get :environment second-config)
            (list (concat "FAKE_CLAUDE_STORE=" second-store) "CLAUDE_CONFIG_DIR=other-account"))
      (push second-config mx-machina-eat-profiles)
      (mx-machina--git repo "worktree" "add" "-b" "other" other)
      (let ((first (mx-machina-create "First" repo "test-eat"))
            (second (mx-machina-create "Second" other "second-eat")))
        (mx-machina-start first)
        (mx-machina-start second)
        (mx-machina-eat-test-wait
         (lambda () (seq-every-p
                     (lambda (id) (equal (mx-machina-session-status (mx-machina-session id)) "live"))
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

(ert-deftest mx-machina-eat-setup-failure-releases-process-timer-and-files ()
  (mx-machina-test-with-eat
    (let ((id (mx-machina-create "Broken setup" repo "test-eat")) buffer directory)
      (unwind-protect
          (let ((mx-machina-eat-setup-hook
                 (list (lambda ()
                         (setq buffer (current-buffer) directory mx-machina-claude--run-directory)
                         (error "Intentional setup failure")))))
            (should-error (mx-machina-start id))
            (should (equal (mx-machina-session-status (mx-machina-session id)) "failed"))
            (should-not (gethash id mx-machina--running))
            (should-not (get-buffer-process buffer))
            (should-not (buffer-local-value 'mx-machina-claude--timer buffer))
            (should-not (file-exists-p directory)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest mx-machina-eat-recovery-resumes-original-account-and-id ()
  (mx-machina-test-with-eat
    (let* ((id (mx-machina-create "Relocated terminal" repo "test-eat"))
           (new (expand-file-name "relocated" temporary)))
      (mx-machina-start id)
      (mx-machina-eat-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (let ((sid (mx-machina-session-conversation (mx-machina-session id))))
        (mx-machina-stop id)
        (rename-file repo new)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (mx-machina-rebind-worktree id new))
        (mx-machina-start id)
        (mx-machina-eat-test-wait
         (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
        (should (equal sid (mx-machina-session-conversation (mx-machina-session id))))
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

(ert-deftest mx-machina-eat-retry-restored-profile-resumes-without-input ()
  (mx-machina-test-with-eat
    (let ((id (mx-machina-create "Restore profile" repo "test-eat")))
      (mx-machina-start id)
      (mx-machina-eat-test-wait
       (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
      (let ((sid (mx-machina-session-conversation (mx-machina-session id)))
            (profiles mx-machina-eat-profiles))
        (mx-machina-stop id)
        (setq mx-machina-eat-profiles nil)
        (should-error (mx-machina-retry id) :type 'user-error)
        (setq mx-machina-eat-profiles profiles)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (mx-machina-retry id))
        (mx-machina-eat-test-wait
         (lambda () (equal (mx-machina-session-status (mx-machina-session id)) "live")))
        (should (equal sid (mx-machina-session-conversation (mx-machina-session id))))
        (with-temp-buffer
          (insert-file-contents (expand-file-name "claude/launches.jsonl" temporary))
          (let* ((rows (mapcar (lambda (line) (json-parse-string line :object-type 'alist))
                               (split-string (buffer-string) "\n" t)))
                 (retry (nth 1 rows)))
            (should (= 2 (length rows)))
            (should (equal (alist-get 'resume retry) sid))
            (should (eq (alist-get 'new retry) :null))
            (should (equal (alist-get 'account retry) "fixture-account"))))
        (with-temp-buffer
          (insert-file-contents (expand-file-name (concat "claude/" sid ".json") temporary))
          (should (zerop (json-parse-string (buffer-string)))))))))

;;; mx-machina-eat-tests.el ends here
