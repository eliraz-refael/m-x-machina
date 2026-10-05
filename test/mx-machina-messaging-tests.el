;;; mx-machina-messaging-tests.el --- CLI messaging regression tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'mx-machina-messaging)
(unless (boundp 'mx-machina-test-root)
  (load (expand-file-name "mx-machina-tests.el" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(defmacro mx-machina-test-with-messaging (&rest body)
  "Run BODY with an isolated message queue without starting a server."
  (declare (indent 0) (debug t))
  `(let ((mx-machina-messaging-mode nil)
         (mx-machina-messaging--records (make-hash-table :test #'equal))
         (mx-machina-messaging--timer nil))
     (unwind-protect
         (progn
           (cl-letf (((symbol-function 'server-start) #'ignore))
             (mx-machina-messaging-mode 1))
           (cancel-timer mx-machina-messaging--timer)
           (setq mx-machina-messaging--timer nil)
           ,@body)
       (mx-machina-messaging-mode -1))))

(defun mx-machina-messaging-test-rpc (data)
  "Call the same JSON entry point as the CLI with DATA."
  (json-parse-string
   (decode-coding-string
    (base64-decode-string (mx-machina-messaging-rpc
                          (base64-encode-string (encode-coding-string (json-encode data) 'utf-8) t))) 'utf-8)
   :object-type 'alist :array-type 'list :null-object nil :false-object nil))

(ert-deftest mx-machina-messaging-queue-identity-cycle-cancel-and-restart ()
  (mx-machina-test-with-store
    (mx-machina-test-with-messaging
      (let* ((a (mx-machina-create "A" repo "test" "Work"))
             (b (mx-machina-create "B" repo "test" "Work"))
             (c (mx-machina-create "C" repo "test" "Work")))
        (dolist (id (list a b c)) (puthash id (cons "run" (mx-machina--transport-create)) mx-machina--running))
        (unwind-protect
            (let ((r (mx-machina-messaging-send "Work/B" "Hello\nλ \"quote\"" a "request-0001")))
              (should (equal (alist-get 'target r) b))
              (should (eq r (mx-machina-messaging-send b "Hello\nλ \"quote\"" a "request-0001")))
              (should-error (mx-machina-messaging-send b "Different" a "request-0001"))
              (should-error (mx-machina-messaging-send a "Self" a))
              (mx-machina-messaging-send c "B to C" b)
              (should-error (mx-machina-messaging-send a "C to A" c))
              (should-not (alist-get 'ok (mx-machina-messaging-test-rpc '((command . "delete-everything")))))
              (should (alist-get 'ok (mx-machina-messaging-test-rpc '((command . "cancel") (request . "request-0001")))))
              (should (equal (alist-get 'status r) "cancelled"))
              (mx-machina-messaging-mode -1)
              (cl-letf (((symbol-function 'server-start) #'ignore)) (mx-machina-messaging-mode 1))
              (should (seq-every-p (lambda (record) (member (alist-get 'status record) '("cancelled" "failed")))
                                   (hash-table-values mx-machina-messaging--records)))
              (should (= (file-modes (mx-machina-messaging--directory)) #o700)))
          (clrhash mx-machina--running))))))

(ert-deftest mx-machina-messaging-refuses-stopped-archived-ambiguous-and-invalid ()
  (mx-machina-test-with-store
    (mx-machina-test-with-messaging
      (let ((id (mx-machina-create "Same" repo "test" "Work")))
        (mx-machina-create "Same" repo "test" "Work")
        (should-error (mx-machina-messaging-send "Work/Same" "Hi"))
        (should-error (mx-machina-messaging-send id "Hi"))
        (should-error (mx-machina-messaging-send id " "))
        (should-error (mx-machina-messaging-send id (make-string 16385 ?a)))
        (should-error (mx-machina-messaging-send id "Hi" nil "../../bad"))
        (mx-machina-archive id)
        (should-error (mx-machina-messaging-send id "Hi"))
        (should (= 0 (hash-table-count mx-machina-messaging--records)))))))

(ert-deftest mx-machina-messaging-crash-record-is-not-replayed ()
  (mx-machina-test-with-store
    (mx-machina-test-with-messaging
      (mx-machina-messaging--save '((id . "request-crashed") (status . "working") (created . 1)))
      ;; Simulate a saved in-flight record left by an abrupt Emacs exit.
      (when mx-machina-messaging--timer (cancel-timer mx-machina-messaging--timer))
      (setq mx-machina-messaging--timer nil)
      (clrhash mx-machina-messaging--records)
      (cl-letf (((symbol-function 'server-start) #'ignore)) (mx-machina-messaging-mode 1))
      (should (equal (alist-get 'status (gethash "request-crashed" mx-machina-messaging--records)) "failed")))))

(ert-deftest mx-machina-messaging-late-ack-keeps-new-draft-and-prunes-only-finished ()
  (mx-machina-test-with-store
    (mx-machina-test-with-messaging
      (with-temp-buffer
        (setq-local mx-machina--managed-id "fixture")
        (let ((transport (mx-machina--transport-create :buffer (current-buffer))))
          (mx-machina-messaging--eat-input nil "draft")
          (mx-machina-messaging--eat-input nil "\r")
          (mx-machina-messaging--eat-input nil "next draft")
          (mx-machina-messaging--event transport 'prompt nil)
          (should mx-machina-messaging--draft)
          (mx-machina-messaging--eat-input nil "\r")
          (mx-machina-messaging--event transport 'prompt nil)
          (should-not mx-machina-messaging--draft)))
      (mx-machina-messaging--save '((id . "old-finished") (status . "completed") (created . 1)))
      (mx-machina-messaging--save '((id . "old-pending") (status . "queued") (created . 1)))
      (let ((mx-machina-messaging--last-prune 0)) (mx-machina-messaging--prune))
      (should-not (gethash "old-finished" mx-machina-messaging--records))
      (should (gethash "old-pending" mx-machina-messaging--records)))))

(ert-deftest mx-machina-messaging-storage-error-does-not-escape-backend-hook ()
  (mx-machina-test-with-store
    (mx-machina-test-with-messaging
      (with-temp-buffer
        (let ((transport (mx-machina--transport-create :buffer (current-buffer)))
              (record (copy-tree '((id . "disk-error") (target . "receiver") (run . "run") (status . "working")))))
          (puthash "receiver" (cons "run" transport) mx-machina--running)
          (puthash "disk-error" record mx-machina-messaging--records)
          (unwind-protect
              (progn
                (cl-letf (((symbol-function 'mx-machina-messaging--save) (lambda (_) (error "disk full"))))
                  (mx-machina-messaging--event transport 'turn-ended '(:text "Complete reply")))
                (should-not mx-machina-messaging-mode)
                (should-not (mx-machina-transport-failed transport))
                (should (gethash "receiver" mx-machina--running)))
            (clrhash mx-machina--running)))))))

(provide 'mx-machina-messaging-tests)

(ert-deftest mx-machina-messaging-whoami-explicit-and-unknown ()
  (mx-machina-test-with-store
    (mx-machina-test-with-messaging
      (let* ((id (mx-machina-create "Named agent" repo "test" "Work"))
             (response (mx-machina-messaging-test-rpc `((command . "whoami") (sender . ,id)))))
        ;; A second agent shares the worktree; directory alone is never identity.
        (mx-machina-create "Other agent" repo "test" "Work")
        (should (alist-get 'ok response))
        (should (equal (alist-get 'id (alist-get 'result response)) id))
        (should (equal (alist-get 'name (alist-get 'result response)) "Work/Named agent"))
        (should (equal (alist-get 'directory (alist-get 'result response)) (file-truename repo)))
        (should-not (alist-get 'ok (mx-machina-messaging-test-rpc '((command . "whoami")))))
        (should-not (alist-get 'ok (mx-machina-messaging-test-rpc '((command . "whoami") (sender . "missing")))))))))

(ert-deftest mx-machina-messaging-process-identity-excludes-stopped-and-cycles ()
  (let* ((mx-machina--running (make-hash-table :test #'equal))
         (transport (mx-machina--transport-create))
         (process (make-pipe-process :name "identity-fixture" :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'mx-machina-backend-process) (lambda (_) process))
                  ((symbol-function 'process-id) (lambda (_) 42))
                  ((symbol-function 'process-attributes)
                   (lambda (pid) (list (cons 'ppid (pcase pid (44 43) (43 42) (_ 44)))))))
          (puthash "owner" (cons "run" transport) mx-machina--running)
          (should (equal (mx-machina-messaging--process-sender 44) "owner"))
          (setf (mx-machina-transport-stopping transport) t)
          (should-not (mx-machina-messaging--process-sender 44))
          (setf (mx-machina-transport-stopping transport) nil
                (mx-machina-transport-failed transport) t)
          (should-not (mx-machina-messaging--process-sender 44))
          (should-not (mx-machina-messaging--process-sender "44")))
      (delete-process process))))
