;;; emacs-agents-store.el --- Durable session registry -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; One Emacs owns a local SQLite registry.  No transcripts or credentials live here.
;;; Code:
(require 'cl-lib)
(require 'sqlite)
(require 'subr-x)
(require 'seq)

(defgroup emacs-agents nil "Persistent coding-agent sessions." :group 'tools)
(defcustom emacs-agents-directory
  (expand-file-name "emacs-agents/" user-emacs-directory)
  "Local directory for the registry.  Set before opening the dashboard."
  :type 'directory)
(defvar emacs-agents--db nil)
(defvar emacs-agents--db-file nil)

(cl-defstruct (emacs-agents-session (:constructor emacs-agents--session-create))
  id name profile directory branch conversation run status activity error
  folder unread model project archived)

(defmacro emacs-agents--with-transaction (db &rest body)
  "Run BODY in DB, rolling back unless its changes commit successfully.
Emacs 29.1's built-in transaction macro commits even when BODY signals."
  (declare (indent 1) (debug (form body)))
  (let ((connection (make-symbol "connection"))
        (committed (make-symbol "committed")))
    `(let ((,connection ,db) ,committed)
       (sqlite-transaction ,connection)
       (unwind-protect
           (prog1 (progn ,@body)
             (unless (sqlite-commit ,connection)
               (error "Could not commit agent registry transaction"))
             (setq ,committed t))
         (unless ,committed (sqlite-rollback ,connection))))))

(defun emacs-agents-store-migrate ()
  "Upgrade the open registry transactionally, without resetting live sessions."
  (let ((version (caar (sqlite-select emacs-agents--db "PRAGMA user_version"))))
    (unless (memq version '(1 2 3)) (error "Unsupported registry schema %s" version))
    (when (= version 1)
      (emacs-agents--with-transaction emacs-agents--db
        (dolist (column '("folder TEXT NOT NULL DEFAULT ''" "unread INTEGER NOT NULL DEFAULT 0"
                          "model TEXT" "project TEXT"))
          (sqlite-execute emacs-agents--db (concat "ALTER TABLE sessions ADD COLUMN " column)))
        (sqlite-execute emacs-agents--db "CREATE TABLE folders (path TEXT PRIMARY KEY)")
        (sqlite-execute emacs-agents--db "PRAGMA user_version=2")))
    (when (< version 3)
      (emacs-agents--with-transaction emacs-agents--db
        (sqlite-execute emacs-agents--db "ALTER TABLE sessions ADD COLUMN archived INTEGER NOT NULL DEFAULT 0")
        (sqlite-execute emacs-agents--db "PRAGMA user_version=3")))))

(defun emacs-agents--id ()
  "Generate a stable registry identifier."
  (secure-hash 'sha256 (format "%s:%s:%s" (current-time) (emacs-pid) (random))))

(defun emacs-agents-store-close ()
  "Close the registry and release its lock after managed runs are stopped."
  (when emacs-agents--db
    (sqlite-close emacs-agents--db)
    (setq emacs-agents--db nil))
  (when emacs-agents--db-file
    (let ((create-lockfiles t)) (unlock-file emacs-agents--db-file))
    (setq emacs-agents--db-file nil)))

(defun emacs-agents-store-ensure-lock (file)
  "Acquire FILE's registry lock even when ordinary editor lockfiles are disabled."
  (let ((owner (file-locked-p file)) (create-lockfiles t))
    (when (and owner (not (eq owner t)))
      (user-error "Another registry owner holds %s" file))
    ;; Reject a competing owner even if it acquired the lock since our check.
    (cl-letf (((symbol-function 'ask-user-about-lock)
               (lambda (&rest _) (user-error "Another registry owner holds %s" file))))
      (lock-file file))
    (unless (eq (file-locked-p file) t)
      (error "Could not acquire registry lock: %s" file))))

(defun emacs-agents-store-open ()
  "Open the registry and recover observations from the previous Emacs instance."
  (unless emacs-agents--db
    (unless (sqlite-available-p) (user-error "Emacs needs SQLite support"))
    (when (file-remote-p emacs-agents-directory)
      (user-error "The registry must be on a local filesystem"))
    (make-directory emacs-agents-directory t)
    (let ((file (expand-file-name "sessions.sqlite" emacs-agents-directory)))
      (emacs-agents-store-ensure-lock file)
      (setq emacs-agents--db-file file)
      (condition-case err
          (progn
            (setq emacs-agents--db (sqlite-open file))
            (set-file-modes file #o600)
            (sqlite-execute emacs-agents--db "PRAGMA foreign_keys=ON")
            (sqlite-execute emacs-agents--db "PRAGMA busy_timeout=2000")
            (let ((version (caar (sqlite-select emacs-agents--db "PRAGMA user_version"))))
              (unless (memq version '(0 1 2 3))
                (error "Unsupported registry schema %s" version))
              (when (= version 0)
                (emacs-agents--with-transaction emacs-agents--db
                  (sqlite-execute emacs-agents--db
                   "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL,
                    profile TEXT NOT NULL, directory TEXT NOT NULL, branch TEXT NOT NULL,
                    conversation TEXT, run TEXT, status TEXT NOT NULL DEFAULT 'stopped',
                    activity TEXT NOT NULL DEFAULT 'unknown', error TEXT,
                    created TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
                  (sqlite-execute emacs-agents--db
                   "CREATE TABLE runs (id TEXT PRIMARY KEY, session TEXT NOT NULL REFERENCES sessions(id),
                    conversation TEXT, started TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    ended TEXT, outcome TEXT)")
                  (sqlite-execute emacs-agents--db "PRAGMA user_version=1"))))
            (emacs-agents-store-migrate)
            (emacs-agents--with-transaction emacs-agents--db
              (sqlite-execute emacs-agents--db
               "UPDATE runs SET ended=CURRENT_TIMESTAMP, outcome='disconnected' WHERE ended IS NULL")
              (sqlite-execute emacs-agents--db
               "UPDATE sessions SET status='stopped', activity='unknown' WHERE status IN ('starting','live')")))
        (error (emacs-agents-store-close) (signal (car err) (cdr err))))))
  emacs-agents--db)

(defun emacs-agents--query (sql &rest values)
  "Query SQL with bound VALUES."
  (sqlite-select (emacs-agents-store-open) sql values))
(defun emacs-agents--exec (sql &rest values)
  "Execute SQL with bound VALUES."
  (sqlite-execute (emacs-agents-store-open) sql values))

(defconst emacs-agents--session-columns
  "id,name,profile,directory,branch,conversation,run,status,activity,error,folder,unread,model,project,archived")

(defun emacs-agents--session-from-row (row)
  "Decode one registry ROW."
  (apply #'emacs-agents--session-create
            (cl-mapcan #'list
                       '(:id :name :profile :directory :branch :conversation :run :status :activity :error
                         :folder :unread :model :project :archived)
                       row)))

(defun emacs-agents-sessions (&optional scope)
  "Return active sessions, oldest first.
SCOPE may be `archived' for archived records or `all' for both."
  (mapcar #'emacs-agents--session-from-row
   (emacs-agents--query
    (concat "SELECT " emacs-agents--session-columns " FROM sessions"
            (pcase scope ('all "") ('archived " WHERE archived=1") (_ " WHERE archived=0"))
            " ORDER BY rowid"))))

(defun emacs-agents-archived-p (session)
  "Return whether SESSION is archived."
  (= (or (emacs-agents-session-archived session) 0) 1))

(defun emacs-agents-folder-path (path)
  "Normalize logical folder PATH.  This is never a filesystem path."
  (let ((parts (split-string (string-trim path) "/" t "[[:space:]]+")))
    (when (seq-some (lambda (part) (or (member part '("." ".."))
                                      (string-match-p "[[:cntrl:]]" part))) parts)
      (user-error "Folder names cannot be . or .. or contain control characters"))
    (string-join parts "/")))

(defun emacs-agents-folders ()
  "Return all logical folder paths, including empty folders."
  (sort (mapcar #'car (emacs-agents--query "SELECT path FROM folders"))
        (lambda (a b)
          (let ((left (split-string a "/")) (right (split-string b "/")))
            (while (and left right (equal (car left) (car right)))
              (setq left (cdr left) right (cdr right)))
            (and right (or (null left) (string-lessp (car left) (car right))))))))

(defun emacs-agents-folder-create (path)
  "Persist logical folder PATH and any missing ancestors, returning its path."
  (setq path (emacs-agents-folder-path path))
  (emacs-agents-store-open)
  (emacs-agents--with-transaction emacs-agents--db
    (let ((prefix ""))
      (dolist (part (split-string path "/" t))
        (setq prefix (if (string-empty-p prefix) part (concat prefix "/" part)))
        (emacs-agents--exec "INSERT OR IGNORE INTO folders(path) VALUES(?)" prefix))))
  path)

(defun emacs-agents-unread-p (session)
  "Return whether SESSION has unseen output."
  (> (or (emacs-agents-session-unread session) 0) 0))

(defun emacs-agents-session (id &optional missing-ok)
  "Return session ID, or signal an error unless MISSING-OK."
  (if-let* ((row (car (emacs-agents--query
                       (concat "SELECT " emacs-agents--session-columns " FROM sessions WHERE id=?") id))))
      (emacs-agents--session-from-row row)
    (unless missing-ok (user-error "Unknown session %s" id))))

(defun emacs-agents--begin-run (id)
  "Allocate and persist a new run for session ID."
  (let ((session (emacs-agents-session id)) (run (emacs-agents--id)))
    (when (emacs-agents-archived-p session) (user-error "Restore this archived agent before starting it"))
    (emacs-agents--with-transaction emacs-agents--db
      (emacs-agents--exec
       "INSERT INTO runs(id,session,conversation) VALUES(?,?,?)"
       run id (emacs-agents-session-conversation session))
      (emacs-agents--exec
       "UPDATE sessions SET run=?,status='starting',activity='unknown',error=NULL WHERE id=?" run id))
    run))

(defun emacs-agents--observe (id run status activity &optional conversation message)
  "Apply an observation to ID only if RUN is current and still active.
Persist CONVERSATION without replacing a previously saved identity.
STATUS, ACTIVITY and MESSAGE describe process, activity and diagnostic state."
  (let ((session (emacs-agents-session id t)))
    (when (and session (equal run (emacs-agents-session-run session))
               (member (emacs-agents-session-status session) '("starting" "live")))
      (when (and conversation (emacs-agents-session-conversation session)
                 (not (equal conversation (emacs-agents-session-conversation session))))
        (error "Backend conversation identity changed"))
      (emacs-agents--with-transaction emacs-agents--db
        (emacs-agents--exec
         "UPDATE sessions SET status=?,activity=?,conversation=COALESCE(conversation,?),error=? WHERE id=?"
         status activity conversation message id)
        (emacs-agents--exec
         "UPDATE runs SET conversation=COALESCE(conversation,?) WHERE id=?" conversation run)
        (unless (member status '("starting" "live"))
          (emacs-agents--exec
           "UPDATE runs SET ended=CURRENT_TIMESTAMP,outcome=? WHERE id=?" status run)))
      t)))

(provide 'emacs-agents-store)
;;; emacs-agents-store.el ends here
