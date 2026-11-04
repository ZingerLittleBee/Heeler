-- The four tables Chat reads from OpenCode 2.0.32's database, with the column
-- order, types and indexes of a store migrated from OpenCode 1.x. Foreign keys
-- are left out.
CREATE TABLE session_v2 (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  workspace_id TEXT,
  parent_id TEXT,
  fork_session_id TEXT,
  fork_boundary TEXT,
  slug TEXT NOT NULL,
  directory TEXT NOT NULL,
  path TEXT,
  title TEXT,
  version TEXT NOT NULL,
  share_url TEXT,
  summary_additions INTEGER,
  summary_deletions INTEGER,
  summary_files INTEGER,
  summary_diffs TEXT,
  metadata TEXT,
  cost REAL DEFAULT 0 NOT NULL,
  tokens_input INTEGER DEFAULT 0 NOT NULL,
  tokens_output INTEGER DEFAULT 0 NOT NULL,
  tokens_reasoning INTEGER DEFAULT 0 NOT NULL,
  tokens_cache_read INTEGER DEFAULT 0 NOT NULL,
  tokens_cache_write INTEGER DEFAULT 0 NOT NULL,
  revert TEXT,
  permission TEXT,
  agent TEXT,
  model TEXT,
  time_created INTEGER NOT NULL,
  time_updated INTEGER NOT NULL,
  time_compacting INTEGER,
  time_archived INTEGER,
  time_suspended INTEGER,
  resume_attempts INTEGER DEFAULT 0 NOT NULL,
  time_idle INTEGER,
  time_viewed INTEGER,
  idle_outcome TEXT
);
CREATE INDEX session_v2_project_idx ON session_v2 (project_id);
CREATE INDEX session_v2_workspace_idx ON session_v2 (workspace_id);
CREATE INDEX session_v2_parent_idx ON session_v2 (parent_id);
CREATE INDEX session_v2_time_suspended_idx ON session_v2 (time_suspended)
  WHERE time_suspended IS NOT NULL;

CREATE TABLE session_message (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  type TEXT NOT NULL,
  seq INTEGER NOT NULL,
  time_created INTEGER NOT NULL,
  time_updated INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message (session_id, seq);
CREATE INDEX session_message_session_type_seq_idx ON session_message (session_id, type, seq);
CREATE INDEX session_message_session_time_created_id_idx
  ON session_message (session_id, time_created, id);
CREATE INDEX session_message_time_created_idx ON session_message (time_created);

CREATE TABLE event_sequence (
  aggregate_id TEXT PRIMARY KEY,
  seq INTEGER NOT NULL,
  owner_id TEXT
);

CREATE TABLE session_inbox (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  type TEXT NOT NULL,
  payload TEXT NOT NULL,
  delivery TEXT NOT NULL,
  enqueued_seq INTEGER NOT NULL,
  time_created INTEGER NOT NULL
);
CREATE UNIQUE INDEX session_inbox_session_enqueued_seq_idx
  ON session_inbox (session_id, enqueued_seq);
CREATE INDEX session_inbox_session_delivery_seq_idx
  ON session_inbox (session_id, delivery, enqueued_seq);
