-- Activity email: manual checks (run in SQL editor or psql via SSH tunnel).
-- Replace UUIDs when using the manual enqueue block at the bottom.

-- 1) Migration applied?
SELECT EXISTS (
  SELECT 1 FROM information_schema.tables
  WHERE table_schema = 'public' AND table_name = 'activity_email_outbox'
) AS outbox_table_exists;

-- 2) Recent outbox rows (pending / sent / failed)
SELECT
  id,
  status,
  recipient_email,
  kind_label,
  left(activity_line, 80) AS activity_line,
  left(summary_snippet, 60) AS summary,
  error_message,
  created_at,
  sent_at
FROM activity_email_outbox
ORDER BY created_at DESC
LIMIT 20;

-- 3) Pending count
SELECT count(*) AS pending FROM activity_email_outbox WHERE status = 'pending';

-- 4) Triggers present?
SELECT tgname, tgrelid::regclass AS table_name
FROM pg_trigger
WHERE tgname IN (
  'trg_enqueue_changelog_activity_emails',
  'trg_enqueue_mention_activity_emails',
  'trg_dispatch_activity_email_outbox'
);

-- 5) People with email (recipients must have this set)
SELECT id, display_name, handle, email
FROM people
WHERE email IS NOT NULL AND trim(email) <> ''
ORDER BY created_at DESC
LIMIT 20;
