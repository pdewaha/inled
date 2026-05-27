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

-- 6) Dashboard: counts by status (simple “did mail fire?” view)
SELECT status, count(*) AS n
FROM activity_email_outbox
GROUP BY status
ORDER BY status;

-- 7) Dashboard: changelog vs mention rows, by status
SELECT source_type, status, count(*) AS n
FROM activity_email_outbox
GROUP BY source_type, status
ORDER BY source_type, status;

-- 8) Dashboard: emails sent in the last 24 hours (uses sent_at)
SELECT count(*) AS sent_last_24h
FROM activity_email_outbox
WHERE status = 'sent'
  AND sent_at IS NOT NULL
  AND sent_at >= now() - interval '24 hours';

-- 9) Dashboard: sent per calendar day (last 14 days)
SELECT date_trunc('day', sent_at AT TIME ZONE 'UTC')::date AS day_utc,
       count(*) AS sent_n
FROM activity_email_outbox
WHERE status = 'sent'
  AND sent_at IS NOT NULL
  AND sent_at >= now() - interval '14 days'
GROUP BY 1
ORDER BY 1 DESC;
