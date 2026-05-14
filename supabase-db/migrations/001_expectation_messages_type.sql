-- App-authored changelog rows use type = 1; chat remains 0.
ALTER TABLE expectation_messages
  ADD COLUMN IF NOT EXISTS type smallint NOT NULL DEFAULT 0;
