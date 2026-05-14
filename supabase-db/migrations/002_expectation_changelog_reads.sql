CREATE TABLE IF NOT EXISTS expectation_changelog_reads (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  expectation_id uuid NOT NULL REFERENCES expectations(id) ON DELETE CASCADE,
  reader_person_id uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  last_read_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (expectation_id, reader_person_id)
);

CREATE INDEX IF NOT EXISTS idx_expectation_changelog_reads_reader
  ON expectation_changelog_reads (reader_person_id);
