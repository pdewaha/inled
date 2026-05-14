-- Nudge flow: "Request update" sets this timestamp and bumps health to at-risk until a substantive save clears it.
ALTER TABLE expectations
  ADD COLUMN IF NOT EXISTS update_requested_at timestamptz;

COMMENT ON COLUMN expectations.update_requested_at IS
  'Set when a party requests an update; cleared when summary or status/health/deadline/progress changes are saved.';
