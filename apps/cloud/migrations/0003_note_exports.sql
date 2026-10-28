CREATE TABLE IF NOT EXISTS workspace_exports (
  owner TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  mime TEXT NOT NULL,
  size INTEGER NOT NULL,
  expires_at TEXT NOT NULL,
  PRIMARY KEY(owner,id)
);
CREATE INDEX IF NOT EXISTS workspace_exports_expiry ON workspace_exports(expires_at);
