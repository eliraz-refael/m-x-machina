;;; emacs-agents-store.el --- Durable session registry -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; One Emacs owns a local SQLite registry.  No transcripts or credentials live here.
;;; Code:
(require 'cl-lib)
(require 'sqlite)
(require 'subr-x)

(defgroup emacs-agents nil "Persistent coding-agent sessions." :group 'tools)
(defcustom emacs-agents-directory
  (expand-file-name "emacs-agents/" user-emacs-directory)
  "Local directory for the registry.  Set before opening the dashboard."
  :type 'directory)
(defvar emacs-agents--db nil)
(defvar emacs-agents--db-file nil)

(cl-defstruct (emacs-agents-session (:constructor emacs-agents--session-create))
  id name profile directory branch conversation run status activity error)

(defun emacs-agents--id ()
  "Generate a stable registry identifier."
  (secure-hash 'sha256 (format "%s:%s:%s" (current-time) (emacs-pid) (random))))

(defun emacs-agents-store-close ()
  "Close the registry and release its lock after managed runs are stopped."
  (when emacs-agents--db
    (sqlite-close emacs-agents--db)
    (setq emacs-agents--db nil))
  (when emacs-agents--db-file
    (unlock-file emacs-agents--db-file)
    (setq emacs-agents--db-file nil)))

(defun emacs-agents-store-open ()
  "Open the registry and recover observations from the previous Emacs instance."
  (unless emacs-agents--db
    (unless (sqlite-available-p) (user-error "Emacs needs SQLite support"))
    (when (file-remote-p emacs-agents-directory)
      (user-error "The registry must be on a local filesystem"))
    (make-directory emacs-agents-directory t)
    (let ((file (expand-file-name "sessions.sqlite" emacs-agents-directory)))
      (when (file-locked-p file)
        (user-error "Another registry owner holds %s" file))
      (lock-file file)
      (setq emacs-agents--db-file file)
      (condition-case err
          (progn
            (setq emacs-agents--db (sqlite-open file))
            (set-file-modes file #o600)
            (sqlite-execute emacs-agents--db "PRAGMA foreign_keys=ON")
            (sqlite-execute emacs-agents--db "PRAGMA busy_timeout=2000")
            (let ((version (caar (sqlite-select emacs-agents--db "PRAGMA user_version"))))
              (unless (memq version '(0 1))
                (error "Unsupported registry schema %s" version))
              (when (= version 0)
                (with-sqlite-transaction emacs-agents--db
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
            (with-sqlite-transaction emacs-agents--db
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

(defun emacs-agents-sessions ()
  "Return all persisted sessions, oldest first."
  (mapcar
   (lambda (row)
     (apply #'emacs-agents--session-create
            (cl-mapcan #'list
                       '(:id :name :profile :directory :branch :conversation :run :status :activity :error)
                       row)))
   (emacs-agents--query
    "SELECT id,name,profile,directory,branch,conversation,run,status,activity,error FROM sessions ORDER BY rowid")))

(defun emacs-agents-session (id)
  "Return session ID, or signal an error."
  (or (cl-find id (emacs-agents-sessions) :key #'emacs-agents-session-id :test #'equal)
      (user-error "Unknown session %s" id)))

(defun emacs-agents--begin-run (id)
  "Allocate and persist a new run for session ID."
  (let ((session (emacs-agents-session id)) (run (emacs-agents--id)))
    (with-sqlite-transaction emacs-agents--db
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
  (let ((session (emacs-agents-session id)))
    (when (and (equal run (emacs-agents-session-run session))
               (member (emacs-agents-session-status session) '("starting" "live")))
      (when (and conversation (emacs-agents-session-conversation session)
                 (not (equal conversation (emacs-agents-session-conversation session))))
        (error "Backend conversation identity changed"))
      (with-sqlite-transaction emacs-agents--db
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
