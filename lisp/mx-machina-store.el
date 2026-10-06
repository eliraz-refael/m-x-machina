;;; mx-machina-store.el --- Durable session registry -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eliraz Kedmi
;; Author: Eliraz Kedmi <eliraz.kedmi@gmail.com>
;; Assisted-by: Codex:gpt-6
;; Maintainer: Eliraz Kedmi <eliraz.kedmi@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later
;; This file is part of M-x Machina.
;;
;; M-x Machina is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; M-x Machina is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with M-x Machina.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; One Emacs owns a local SQLite registry.  No transcripts or credentials live here.
;;; Code:
(require 'cl-lib)
(require 'sqlite)
(require 'subr-x)
(require 'seq)

(defgroup mx-machina nil "Persistent coding-agent sessions." :group 'tools)
(defcustom mx-machina-directory
  ;; Preserve the historical on-disk location so existing agents remain available.
  (expand-file-name "emacs-agents/" user-emacs-directory)
  "Local directory for the registry.  Set before opening the dashboard."
  :type 'directory)
(defvar mx-machina--db nil)
(defvar mx-machina--db-file nil)

(cl-defstruct (mx-machina-session (:constructor mx-machina--session-create))
  id name profile directory branch conversation run status activity error
  folder unread model project archived)

(defmacro mx-machina--with-transaction (db &rest body)
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

(defun mx-machina-store-migrate ()
  "Upgrade the open registry transactionally, without resetting live sessions."
  (let ((version (caar (sqlite-select mx-machina--db "PRAGMA user_version"))))
    (unless (memq version '(1 2 3)) (error "Unsupported registry schema %s" version))
    (when (= version 1)
      (mx-machina--with-transaction mx-machina--db
        (dolist (column '("folder TEXT NOT NULL DEFAULT ''" "unread INTEGER NOT NULL DEFAULT 0"
                          "model TEXT" "project TEXT"))
          (sqlite-execute mx-machina--db (concat "ALTER TABLE sessions ADD COLUMN " column)))
        (sqlite-execute mx-machina--db "CREATE TABLE folders (path TEXT PRIMARY KEY)")
        (sqlite-execute mx-machina--db "PRAGMA user_version=2")))
    (when (< version 3)
      (mx-machina--with-transaction mx-machina--db
        (sqlite-execute mx-machina--db "ALTER TABLE sessions ADD COLUMN archived INTEGER NOT NULL DEFAULT 0")
        (sqlite-execute mx-machina--db "PRAGMA user_version=3")))))

(defun mx-machina--id ()
  "Generate a stable registry identifier."
  (secure-hash 'sha256 (format "%s:%s:%s" (current-time) (emacs-pid) (random))))

(defun mx-machina-store-close ()
  "Close the registry and release its lock after managed runs are stopped."
  (when mx-machina--db
    (sqlite-close mx-machina--db)
    (setq mx-machina--db nil))
  (when mx-machina--db-file
    (let ((create-lockfiles t)) (unlock-file mx-machina--db-file))
    (setq mx-machina--db-file nil)))

(defun mx-machina-store-ensure-lock (file)
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

(defun mx-machina-store-open ()
  "Open the registry and recover observations from the previous Emacs instance."
  (unless mx-machina--db
    (unless (sqlite-available-p) (user-error "Emacs needs SQLite support"))
    (when (file-remote-p mx-machina-directory)
      (user-error "The registry must be on a local filesystem"))
    (make-directory mx-machina-directory t)
    (let ((file (expand-file-name "sessions.sqlite" mx-machina-directory)))
      (mx-machina-store-ensure-lock file)
      (setq mx-machina--db-file file)
      (condition-case err
          (progn
            (setq mx-machina--db (sqlite-open file))
            (set-file-modes file #o600)
            (sqlite-execute mx-machina--db "PRAGMA foreign_keys=ON")
            (sqlite-execute mx-machina--db "PRAGMA busy_timeout=2000")
            (let ((version (caar (sqlite-select mx-machina--db "PRAGMA user_version"))))
              (unless (memq version '(0 1 2 3))
                (error "Unsupported registry schema %s" version))
              (when (= version 0)
                (mx-machina--with-transaction mx-machina--db
                  (sqlite-execute mx-machina--db
                   "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL,
                    profile TEXT NOT NULL, directory TEXT NOT NULL, branch TEXT NOT NULL,
                    conversation TEXT, run TEXT, status TEXT NOT NULL DEFAULT 'stopped',
                    activity TEXT NOT NULL DEFAULT 'unknown', error TEXT,
                    created TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
                  (sqlite-execute mx-machina--db
                   "CREATE TABLE runs (id TEXT PRIMARY KEY, session TEXT NOT NULL REFERENCES sessions(id),
                    conversation TEXT, started TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    ended TEXT, outcome TEXT)")
                  (sqlite-execute mx-machina--db "PRAGMA user_version=1"))))
            (mx-machina-store-migrate)
            (mx-machina--with-transaction mx-machina--db
              (sqlite-execute mx-machina--db
               "UPDATE runs SET ended=CURRENT_TIMESTAMP, outcome='disconnected' WHERE ended IS NULL")
              (sqlite-execute mx-machina--db
               "UPDATE sessions SET status='stopped', activity='unknown' WHERE status IN ('starting','live')")))
        (error (mx-machina-store-close) (signal (car err) (cdr err))))))
  mx-machina--db)

(defun mx-machina--query (sql &rest values)
  "Query SQL with bound VALUES."
  (sqlite-select (mx-machina-store-open) sql values))
(defun mx-machina--exec (sql &rest values)
  "Execute SQL with bound VALUES."
  (sqlite-execute (mx-machina-store-open) sql values))

(defconst mx-machina--session-columns
  "id,name,profile,directory,branch,conversation,run,status,activity,error,folder,unread,model,project,archived")

(defun mx-machina--session-from-row (row)
  "Decode one registry ROW."
  (apply #'mx-machina--session-create
            (cl-mapcan #'list
                       '(:id :name :profile :directory :branch :conversation :run :status :activity :error
                         :folder :unread :model :project :archived)
                       row)))

(defun mx-machina-sessions (&optional scope)
  "Return active sessions, oldest first.
SCOPE may be `archived' for archived records or `all' for both."
  (mapcar #'mx-machina--session-from-row
   (mx-machina--query
    (concat "SELECT " mx-machina--session-columns " FROM sessions"
            (pcase scope ('all "") ('archived " WHERE archived=1") (_ " WHERE archived=0"))
            " ORDER BY rowid"))))

(defun mx-machina-archived-p (session)
  "Return whether SESSION is archived."
  (= (or (mx-machina-session-archived session) 0) 1))

(defun mx-machina-folder-path (path)
  "Normalize logical folder PATH.  This is never a filesystem path."
  (let ((parts (split-string (string-trim path) "/" t "[[:space:]]+")))
    (when (seq-some (lambda (part) (or (member part '("." ".."))
                                      (string-match-p "[[:cntrl:]]" part))) parts)
      (user-error "Folder names cannot be . or .. or contain control characters"))
    (string-join parts "/")))

(defun mx-machina-folders ()
  "Return all logical folder paths, including empty folders."
  (sort (mapcar #'car (mx-machina--query "SELECT path FROM folders"))
        (lambda (a b)
          (let ((left (split-string a "/")) (right (split-string b "/")))
            (while (and left right (equal (car left) (car right)))
              (setq left (cdr left) right (cdr right)))
            (and right (or (null left) (string-lessp (car left) (car right))))))))

(defun mx-machina-folder-create (path)
  "Persist logical folder PATH and any missing ancestors, returning its path."
  (setq path (mx-machina-folder-path path))
  (mx-machina-store-open)
  (mx-machina--with-transaction mx-machina--db
    (let ((prefix ""))
      (dolist (part (split-string path "/" t))
        (setq prefix (if (string-empty-p prefix) part (concat prefix "/" part)))
        (mx-machina--exec "INSERT OR IGNORE INTO folders(path) VALUES(?)" prefix))))
  path)

(defun mx-machina-unread-p (session)
  "Return whether SESSION has unseen output."
  (> (or (mx-machina-session-unread session) 0) 0))

(defun mx-machina-session (id &optional missing-ok)
  "Return session ID, or signal an error unless MISSING-OK."
  (if-let* ((row (car (mx-machina--query
                       (concat "SELECT " mx-machina--session-columns " FROM sessions WHERE id=?") id))))
      (mx-machina--session-from-row row)
    (unless missing-ok (user-error "Unknown session %s" id))))

(defun mx-machina--begin-run (id)
  "Allocate and persist a new run for session ID."
  (let ((session (mx-machina-session id)) (run (mx-machina--id)))
    (when (mx-machina-archived-p session) (user-error "Restore this archived agent before starting it"))
    (mx-machina--with-transaction mx-machina--db
      (mx-machina--exec
       "INSERT INTO runs(id,session,conversation) VALUES(?,?,?)"
       run id (mx-machina-session-conversation session))
      (mx-machina--exec
       "UPDATE sessions SET run=?,status='starting',activity='unknown',error=NULL WHERE id=?" run id))
    run))

(defun mx-machina--observe (id run status activity &optional conversation message)
  "Apply an observation to ID only if RUN is current and still active.
Persist CONVERSATION without replacing a previously saved identity.
STATUS, ACTIVITY and MESSAGE describe process, activity and diagnostic state."
  (let ((session (mx-machina-session id t)))
    (when (and session (equal run (mx-machina-session-run session))
               (member (mx-machina-session-status session) '("starting" "live")))
      (when (and conversation (mx-machina-session-conversation session)
                 (not (equal conversation (mx-machina-session-conversation session))))
        (error "Backend conversation identity changed"))
      (mx-machina--with-transaction mx-machina--db
        (mx-machina--exec
         "UPDATE sessions SET status=?,activity=?,conversation=COALESCE(conversation,?),error=? WHERE id=?"
         status activity conversation message id)
        (mx-machina--exec
         "UPDATE runs SET conversation=COALESCE(conversation,?) WHERE id=?" conversation run)
        (unless (member status '("starting" "live"))
          (mx-machina--exec
           "UPDATE runs SET ended=CURRENT_TIMESTAMP,outcome=? WHERE id=?" status run)))
      t)))

(provide 'mx-machina-store)
;;; mx-machina-store.el ends here
