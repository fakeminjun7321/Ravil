CREATE TABLE IF NOT EXISTS workspace_push_subscriptions (owner TEXT NOT NULL REFERENCES user(id), id TEXT NOT NULL, subscription TEXT NOT NULL, last_sent_day TEXT, stopped INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(owner,id));
CREATE TABLE IF NOT EXISTS workspace_calendar_jobs (owner TEXT PRIMARY KEY REFERENCES user(id), locked_until INTEGER NOT NULL DEFAULT 0, summary TEXT NOT NULL DEFAULT '');
