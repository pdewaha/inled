-- App: type 2 = chat row with file attachment(s); excluded from changelog watermarks like type 0.
COMMENT ON COLUMN expectation_messages.type IS
  '0 = chat; 2 = chat with attachment(s); 1 = plain changelog; 10–14 = structured changelog JSON.';
