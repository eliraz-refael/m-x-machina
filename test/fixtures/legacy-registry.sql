-- Synthetic registry created by the pre-rename emacs-agents-store.
BEGIN TRANSACTION;
CREATE TABLE folders (path TEXT PRIMARY KEY);
INSERT INTO "folders" VALUES('Work/Panel');
CREATE TABLE runs (id TEXT PRIMARY KEY, session TEXT NOT NULL REFERENCES sessions(id),
                    conversation TEXT, started TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    ended TEXT, outcome TEXT);
CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL,
                    profile TEXT NOT NULL, directory TEXT NOT NULL, branch TEXT NOT NULL,
                    conversation TEXT, run TEXT, status TEXT NOT NULL DEFAULT 'stopped',
                    activity TEXT NOT NULL DEFAULT 'unknown', error TEXT,
                    created TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, folder TEXT NOT NULL DEFAULT '', unread INTEGER NOT NULL DEFAULT 0, model TEXT, project TEXT, archived INTEGER NOT NULL DEFAULT 0);
INSERT INTO "sessions" VALUES('legacy-agent-id','Saved agent','claude-eat-work','/tmp/saved-worktree/','feature/saved','saved-conversation',NULL,'stopped','unknown',NULL,'2026-10-05 15:42:49','Work/Panel',0,'saved-model',NULL,0);
COMMIT;
PRAGMA user_version=3;
