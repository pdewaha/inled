-- @mentions on public talking points (and future use). Not the same as
-- expectations.target_person_id (single addressee for expectations / private notes).

CREATE TABLE IF NOT EXISTS expectation_mentions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  expectation_id uuid NOT NULL REFERENCES expectations(id) ON DELETE CASCADE,
  mentioned_person_id uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_expectation_mentions_expectation_person
    UNIQUE (expectation_id, mentioned_person_id)
);

CREATE INDEX IF NOT EXISTS idx_expectation_mentions_company_person
  ON expectation_mentions (company_id, mentioned_person_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_expectation_mentions_expectation
  ON expectation_mentions (expectation_id);
