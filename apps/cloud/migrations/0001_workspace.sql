PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS user (id TEXT PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, emailVerified INTEGER NOT NULL DEFAULT 0, image TEXT, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS session (id TEXT PRIMARY KEY, expiresAt INTEGER NOT NULL, token TEXT NOT NULL UNIQUE, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL, ipAddress TEXT, userAgent TEXT, userId TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE);
CREATE INDEX IF NOT EXISTS session_user ON session(userId);
CREATE TABLE IF NOT EXISTS account (id TEXT PRIMARY KEY, accountId TEXT NOT NULL, providerId TEXT NOT NULL, userId TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE, accessToken TEXT, refreshToken TEXT, idToken TEXT, accessTokenExpiresAt INTEGER, refreshTokenExpiresAt INTEGER, scope TEXT, password TEXT, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS account_user ON account(userId);
CREATE TABLE IF NOT EXISTS verification (id TEXT PRIMARY KEY, identifier TEXT NOT NULL, value TEXT NOT NULL, expiresAt INTEGER NOT NULL, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS rateLimit (id TEXT PRIMARY KEY, key TEXT NOT NULL UNIQUE, count INTEGER NOT NULL, lastRequest INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS workspace_entities (owner TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE, id TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('record','subject','project','task','observation','preference')), payload TEXT NOT NULL CHECK(json_valid(payload)), revision INTEGER NOT NULL DEFAULT 1, deleted INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL, PRIMARY KEY(owner,id));
CREATE INDEX IF NOT EXISTS workspace_owner_kind ON workspace_entities(owner,kind,deleted);
CREATE TABLE IF NOT EXISTS workspace_meta (owner TEXT PRIMARY KEY REFERENCES user(id), revision INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS workspace_files (owner TEXT NOT NULL REFERENCES user(id), id TEXT NOT NULL, name TEXT NOT NULL, mime TEXT NOT NULL, size INTEGER NOT NULL, digest TEXT NOT NULL, object_key TEXT NOT NULL, PRIMARY KEY(owner,id));
CREATE TABLE IF NOT EXISTS workspace_backups (id TEXT PRIMARY KEY, owner TEXT NOT NULL, project_id TEXT NOT NULL, workspace_revision INTEGER NOT NULL, digest TEXT NOT NULL, verified INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS workspace_archive_commits (id TEXT PRIMARY KEY, owner TEXT NOT NULL, backup_id TEXT NOT NULL REFERENCES workspace_backups(id));
CREATE TRIGGER IF NOT EXISTS workspace_archive_guard BEFORE INSERT ON workspace_archive_commits BEGIN
  SELECT RAISE(ABORT,'backup_not_verified_or_stale') WHERE NOT EXISTS (
    SELECT 1 FROM workspace_backups b JOIN workspace_meta m ON m.owner=b.owner
    WHERE b.id=NEW.backup_id AND b.owner=NEW.owner AND b.verified=1 AND b.workspace_revision=m.revision
  );
END;
CREATE TABLE IF NOT EXISTS workspace_calendar_credentials (owner TEXT PRIMARY KEY REFERENCES user(id), encrypted TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS workspace_calendar_links (owner TEXT NOT NULL, block_id TEXT NOT NULL, event_id TEXT NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(owner,block_id));
