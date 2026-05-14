-- Per-message read receipts for expectation chat (types 0 and 2): when the counterparty
-- opens the thread, rows are inserted so senders can show WhatsApp-style "seen" state.

CREATE TABLE IF NOT EXISTS expectation_message_reads (
  message_id uuid NOT NULL REFERENCES expectation_messages(id) ON DELETE CASCADE,
  reader_person_id uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  read_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, reader_person_id)
);

CREATE INDEX IF NOT EXISTS idx_expectation_message_reads_reader
  ON expectation_message_reads (reader_person_id);

CREATE INDEX IF NOT EXISTS idx_expectation_message_reads_company
  ON expectation_message_reads (company_id);

ALTER TABLE expectation_message_reads ENABLE ROW LEVEL SECURITY;
