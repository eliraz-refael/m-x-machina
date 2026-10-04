;;; emacs-agents-messaging-tests.el --- CLI messaging regression tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'emacs-agents-messaging)
(unless (boundp 'emacs-agents-test-root)
  (load (expand-file-name "emacs-agents-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(defmacro emacs-agents-test-with-messaging (&rest body)
  "Run BODY with an isolated message queue without starting a server."
  (declare (indent 0) (debug t))
  `(let ((emacs-agents-messaging-mode nil)
         (emacs-agents-messaging--records (make-hash-table :test #'equal))
         (emacs-agents-messaging--timer nil))
     (unwind-protect
         (progn
           (cl-letf (((symbol-function 'server-start) #'ignore))
             (emacs-agents-messaging-mode 1))
           (cancel-timer emacs-agents-messaging--timer)
           (setq emacs-agents-messaging--timer nil)
           ,@body)
       (emacs-agents-messaging-mode -1))))

(defun emacs-agents-messaging-test-rpc (data)
  "Call the same JSON entry point as the CLI with DATA."
  (json-parse-string
   (decode-coding-string
    (base64-decode-string (emacs-agents-messaging-rpc
                          (base64-encode-string (encode-coding-string (json-encode data) 'utf-8) t))) 'utf-8)
   :object-type 'alist :array-type 'list :null-object nil :false-object nil))

(ert-deftest emacs-agents-messaging-queue-identity-cycle-cancel-and-restart ()
  (emacs-agents-test-with-store
    (emacs-agents-test-with-messaging
      (let* ((a (emacs-agents-create "A" repo "test" "Work"))
             (b (emacs-agents-create "B" repo "test" "Work"))
             (c (emacs-agents-create "C" repo "test" "Work")))
        (dolist (id (list a b c)) (puthash id (cons "run" (emacs-agents--transport-create)) emacs-agents--running))
        (unwind-protect
            (let ((r (emacs-agents-messaging-send "Work/B" "Hello\nλ \"quote\"" a "request-0001")))
              (should (equal (alist-get 'target r) b))
              (should (eq r (emacs-agents-messaging-send b "Hello\nλ \"quote\"" a "request-0001")))
              (should-error (emacs-agents-messaging-send b "Different" a "request-0001"))
              (should-error (emacs-agents-messaging-send a "Self" a))
              (emacs-agents-messaging-send c "B to C" b)
              (should-error (emacs-agents-messaging-send a "C to A" c))
              (should-not (alist-get 'ok (emacs-agents-messaging-test-rpc '((command . "delete-everything")))))
              (should (alist-get 'ok (emacs-agents-messaging-test-rpc '((command . "cancel") (request . "request-0001")))))
              (should (equal (alist-get 'status r) "cancelled"))
              (emacs-agents-messaging-mode -1)
              (cl-letf (((symbol-function 'server-start) #'ignore)) (emacs-agents-messaging-mode 1))
              (should (seq-every-p (lambda (record) (member (alist-get 'status record) '("cancelled" "failed")))
                                   (hash-table-values emacs-agents-messaging--records)))
              (should (= (file-modes (emacs-agents-messaging--directory)) #o700)))
          (clrhash emacs-agents--running))))))

(ert-deftest emacs-agents-messaging-refuses-stopped-archived-ambiguous-and-invalid ()
  (emacs-agents-test-with-store
    (emacs-agents-test-with-messaging
      (let ((id (emacs-agents-create "Same" repo "test" "Work")))
        (emacs-agents-create "Same" repo "test" "Work")
        (should-error (emacs-agents-messaging-send "Work/Same" "Hi"))
        (should-error (emacs-agents-messaging-send id "Hi"))
        (should-error (emacs-agents-messaging-send id " "))
        (should-error (emacs-agents-messaging-send id (make-string 16385 ?a)))
        (should-error (emacs-agents-messaging-send id "Hi" nil "../../bad"))
        (emacs-agents-archive id)
        (should-error (emacs-agents-messaging-send id "Hi"))
        (should (= 0 (hash-table-count emacs-agents-messaging--records)))))))

(ert-deftest emacs-agents-messaging-crash-record-is-not-replayed ()
  (emacs-agents-test-with-store
    (emacs-agents-test-with-messaging
      (emacs-agents-messaging--save '((id . "request-crashed") (status . "working") (created . 1)))
      ;; Simulate a saved in-flight record left by an abrupt Emacs exit.
      (when emacs-agents-messaging--timer (cancel-timer emacs-agents-messaging--timer))
      (setq emacs-agents-messaging--timer nil)
      (clrhash emacs-agents-messaging--records)
      (cl-letf (((symbol-function 'server-start) #'ignore)) (emacs-agents-messaging-mode 1))
      (should (equal (alist-get 'status (gethash "request-crashed" emacs-agents-messaging--records)) "failed")))))

(ert-deftest emacs-agents-messaging-late-ack-keeps-new-draft-and-prunes-only-finished ()
  (emacs-agents-test-with-store
    (emacs-agents-test-with-messaging
      (with-temp-buffer
        (setq-local emacs-agents--managed-id "fixture")
        (let ((transport (emacs-agents--transport-create :buffer (current-buffer))))
          (emacs-agents-messaging--eat-input nil "draft")
          (emacs-agents-messaging--eat-input nil "\r")
          (emacs-agents-messaging--eat-input nil "next draft")
          (emacs-agents-messaging--event transport 'prompt nil)
          (should emacs-agents-messaging--draft)
          (emacs-agents-messaging--eat-input nil "\r")
          (emacs-agents-messaging--event transport 'prompt nil)
          (should-not emacs-agents-messaging--draft)))
      (emacs-agents-messaging--save '((id . "old-finished") (status . "completed") (created . 1)))
      (emacs-agents-messaging--save '((id . "old-pending") (status . "queued") (created . 1)))
      (let ((emacs-agents-messaging--last-prune 0)) (emacs-agents-messaging--prune))
      (should-not (gethash "old-finished" emacs-agents-messaging--records))
      (should (gethash "old-pending" emacs-agents-messaging--records)))))

(ert-deftest emacs-agents-messaging-storage-error-does-not-escape-backend-hook ()
  (emacs-agents-test-with-store
    (emacs-agents-test-with-messaging
      (with-temp-buffer
        (let ((transport (emacs-agents--transport-create :buffer (current-buffer)))
              (record (copy-tree '((id . "disk-error") (target . "receiver") (run . "run") (status . "working")))))
          (puthash "receiver" (cons "run" transport) emacs-agents--running)
          (puthash "disk-error" record emacs-agents-messaging--records)
          (unwind-protect
              (progn
                (cl-letf (((symbol-function 'emacs-agents-messaging--save) (lambda (_) (error "disk full"))))
                  (emacs-agents-messaging--event transport 'turn-ended '(:text "Complete reply")))
                (should-not emacs-agents-messaging-mode)
                (should-not (emacs-agents-transport-failed transport))
                (should (gethash "receiver" emacs-agents--running)))
            (clrhash emacs-agents--running)))))))

(provide 'emacs-agents-messaging-tests)

(ert-deftest emacs-agents-messaging-whoami-explicit-and-unknown ()
  (emacs-agents-test-with-store
    (emacs-agents-test-with-messaging
      (let* ((id (emacs-agents-create "Named agent" repo "test" "Work"))
             (response (emacs-agents-messaging-test-rpc `((command . "whoami") (sender . ,id)))))
        ;; A second agent shares the worktree; directory alone is never identity.
        (emacs-agents-create "Other agent" repo "test" "Work")
        (should (alist-get 'ok response))
        (should (equal (alist-get 'id (alist-get 'result response)) id))
        (should (equal (alist-get 'name (alist-get 'result response)) "Work/Named agent"))
        (should (equal (alist-get 'directory (alist-get 'result response)) (file-truename repo)))
        (should-not (alist-get 'ok (emacs-agents-messaging-test-rpc '((command . "whoami")))))
        (should-not (alist-get 'ok (emacs-agents-messaging-test-rpc '((command . "whoami") (sender . "missing")))))))))

(ert-deftest emacs-agents-messaging-process-identity-excludes-stopped-and-cycles ()
  (let* ((emacs-agents--running (make-hash-table :test #'equal))
         (transport (emacs-agents--transport-create))
         (process (make-pipe-process :name "identity-fixture" :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-agents-backend-process) (lambda (_) process))
                  ((symbol-function 'process-id) (lambda (_) 42))
                  ((symbol-function 'process-attributes)
                   (lambda (pid) (list (cons 'ppid (pcase pid (44 43) (43 42) (_ 44)))))))
          (puthash "owner" (cons "run" transport) emacs-agents--running)
          (should (equal (emacs-agents-messaging--process-sender 44) "owner"))
          (setf (emacs-agents-transport-stopping transport) t)
          (should-not (emacs-agents-messaging--process-sender 44))
          (setf (emacs-agents-transport-stopping transport) nil
                (emacs-agents-transport-failed transport) t)
          (should-not (emacs-agents-messaging--process-sender 44))
          (should-not (emacs-agents-messaging--process-sender "44")))
      (delete-process process))))
