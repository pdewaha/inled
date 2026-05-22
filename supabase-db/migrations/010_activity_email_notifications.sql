-- Activity email notifications (bell-aligned, works when user is offline).
-- 1) Apply this migration on Supabase.
-- 2) Deploy Edge Function: supabase/functions/send-activity-email
-- 3) Set Edge Function secrets (same SMTP mailbox as GoTrue / Open-Xchange OTP):
--    SMTP_HOSTNAME, SMTP_PORT, SMTP_SECURE, SMTP_USERNAME, SMTP_PASSWORD, SMTP_FROM, EXLED_APP_URL
-- 4) Hook delivery:
--    Recommended: migration 011 + scripts/setup-activity-email-immediate-dispatch.sh (pg_net on INSERT).
--    Fallback: cron / manual POST { "process_pending": true } or Database Webhook on INSERT.
-- Self-hosted deploy: scripts/setup-beacon-edge-functions.sh + scripts/ACTIVITY_EMAIL.md

CREATE TABLE IF NOT EXISTS activity_email_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  expectation_id uuid NOT NULL REFERENCES expectations(id) ON DELETE CASCADE,
  recipient_person_id uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  recipient_email text NOT NULL,
  sender_person_id uuid REFERENCES people(id) ON DELETE SET NULL,
  sender_label text NOT NULL DEFAULT 'Someone',
  source_type text NOT NULL CHECK (source_type IN ('changelog', 'mention')),
  source_id uuid NOT NULL,
  kind_label text NOT NULL DEFAULT 'Update',
  activity_line text NOT NULL,
  summary_snippet text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'sent', 'failed', 'skipped')),
  error_message text,
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz,
  CONSTRAINT uq_activity_email_outbox_source_recipient
    UNIQUE (source_type, source_id, recipient_person_id)
);

CREATE INDEX IF NOT EXISTS idx_activity_email_outbox_pending
  ON activity_email_outbox (status, created_at)
  WHERE status = 'pending';

ALTER TABLE activity_email_outbox ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.activity_email_outbox TO service_role;

-- Resolve party recipients with email (service role / triggers only).
CREATE OR REPLACE FUNCTION inled_activity_email_recipients(
  p_expectation_id uuid,
  p_exclude_person_id uuid
)
RETURNS TABLE (person_id uuid, email text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH exp AS (
    SELECT
      e.id,
      e.company_id,
      e.target_person_id,
      e.expectation_type,
      e.expectation_visibility
    FROM expectations e
    WHERE e.id = p_expectation_id
  ),
  targets AS (
    SELECT tp.id AS person_id, tp.email
    FROM exp
    JOIN people tp ON tp.id = exp.target_person_id
    WHERE exp.target_person_id IS NOT NULL
    UNION
    SELECT m.mentioned_person_id, p.email
    FROM exp
    JOIN expectation_mentions m ON m.expectation_id = exp.id
    JOIN people p ON p.id = m.mentioned_person_id
    WHERE NOT (exp.expectation_type = 1 AND exp.expectation_visibility = 0)
  )
  SELECT DISTINCT t.person_id, NULLIF(trim(t.email), '') AS email
  FROM targets t
  WHERE t.person_id IS NOT NULL
    AND (p_exclude_person_id IS NULL OR t.person_id <> p_exclude_person_id)
    AND NULLIF(trim(t.email), '') IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION inled_activity_email_sender_label(p_person_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    NULLIF(trim(p.display_name), ''),
    CASE
      WHEN NULLIF(trim(p.handle), '') IS NOT NULL THEN '@' || trim(p.handle)
      ELSE 'Someone'
    END
  )
  FROM people p
  WHERE p.id = p_person_id;
$$;

CREATE OR REPLACE FUNCTION inled_changelog_email_activity_line(
  p_type smallint,
  p_message_text text,
  p_is_topic boolean
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  t text;
  lower_t text;
BEGIN
  t := trim(COALESCE(p_message_text, ''));
  lower_t := lower(t);
  IF t = '' THEN
    RETURN 'New activity on this '
      || CASE WHEN p_is_topic THEN 'talking point' ELSE 'expectation' END
      || '.';
  END IF;
  IF lower_t LIKE 'created a new %' OR lower_t LIKE 'published this %' THEN
    RETURN t;
  END IF;
  IF p_type = 14 THEN
    RETURN 'Published this '
      || CASE WHEN p_is_topic THEN 'talking point' ELSE 'expectation' END
      || '.';
  END IF;
  IF p_type = 15 THEN
    RETURN 'Requested an update — consider progress, deadline, or status.';
  END IF;
  IF p_type IN (10, 11, 12, 13) THEN
    RETURN 'Updated this '
      || CASE WHEN p_is_topic THEN 'talking point' ELSE 'expectation' END
      || '.';
  END IF;
  RETURN left(t, 240);
END;
$$;

CREATE OR REPLACE FUNCTION inled_enqueue_changelog_activity_emails()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  exp_rec record;
  sender_label text;
  activity_line text;
  snippet text;
  kind text;
  is_topic boolean;
  lower_msg text;
  recip record;
BEGIN
  IF NEW.type IN (0, 2) THEN
    RETURN NEW;
  END IF;

  SELECT
    e.id,
    e.company_id,
    e.summary,
    e.expectation_type,
    e.expectation_visibility,
    e.writer_user_id
  INTO exp_rec
  FROM expectations e
  WHERE e.id = NEW.expectation_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  is_topic := exp_rec.expectation_type = 1;
  kind := CASE WHEN is_topic THEN 'Talking point' ELSE 'Expectation' END;
  snippet := left(trim(regexp_replace(exp_rec.summary, '\s+', ' ', 'g')), 120);
  IF length(trim(exp_rec.summary)) > 120 THEN
    snippet := snippet || '…';
  END IF;
  IF snippet = '' THEN
    snippet := '—';
  END IF;

  lower_msg := lower(trim(NEW.message_text));
  -- Private prep talking points: no email until published (echo).
  IF is_topic AND exp_rec.expectation_visibility = 0 THEN
    RETURN NEW;
  END IF;

  sender_label := inled_activity_email_sender_label(NEW.sender_person_id);
  activity_line := inled_changelog_email_activity_line(
    NEW.type,
    NEW.message_text,
    is_topic
  );

  FOR recip IN
    SELECT * FROM inled_activity_email_recipients(NEW.expectation_id, NEW.sender_person_id)
  LOOP
    -- Match bell: do not email the author their own "created a new …" line.
    IF lower_msg LIKE 'created a new expectation%'
       OR lower_msg LIKE 'created a new talking point%' THEN
      IF EXISTS (
        SELECT 1
        FROM people pw
        WHERE pw.id = recip.person_id
          AND pw.auth_user_id = exp_rec.writer_user_id
          AND pw.company_id = exp_rec.company_id
      ) THEN
        CONTINUE;
      END IF;
    END IF;

    INSERT INTO activity_email_outbox (
      company_id,
      expectation_id,
      recipient_person_id,
      recipient_email,
      sender_person_id,
      sender_label,
      source_type,
      source_id,
      kind_label,
      activity_line,
      summary_snippet
    ) VALUES (
      exp_rec.company_id,
      NEW.expectation_id,
      recip.person_id,
      recip.email,
      NEW.sender_person_id,
      sender_label,
      'changelog',
      NEW.id,
      kind,
      activity_line,
      snippet
    )
    ON CONFLICT ON CONSTRAINT uq_activity_email_outbox_source_recipient DO NOTHING;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_changelog_activity_emails ON expectation_messages;
CREATE TRIGGER trg_enqueue_changelog_activity_emails
  AFTER INSERT ON expectation_messages
  FOR EACH ROW
  EXECUTE FUNCTION inled_enqueue_changelog_activity_emails();

CREATE OR REPLACE FUNCTION inled_enqueue_mention_activity_emails()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  exp_rec record;
  sender_label text;
  snippet text;
  kind text;
  activity_line text;
  recip_email text;
  writer_person_id uuid;
BEGIN
  SELECT
    e.id,
    e.company_id,
    e.summary,
    e.expectation_type,
    e.expectation_visibility,
    e.writer_user_id
  INTO exp_rec
  FROM expectations e
  WHERE e.id = NEW.expectation_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  -- Mentions feed is echo-only (published).
  IF exp_rec.expectation_visibility <> 1 THEN
    RETURN NEW;
  END IF;

  -- Talking-point @mentions are surfaced via publish changelog emails; avoid duplicate mail.
  IF exp_rec.expectation_type = 1 THEN
    RETURN NEW;
  END IF;

  IF NEW.mentioned_person_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT NULLIF(trim(p.email), '')
  INTO recip_email
  FROM people p
  WHERE p.id = NEW.mentioned_person_id;

  IF recip_email IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT p.id
  INTO writer_person_id
  FROM people p
  WHERE p.auth_user_id = exp_rec.writer_user_id
    AND p.company_id = exp_rec.company_id
  LIMIT 1;

  IF writer_person_id IS NOT NULL AND writer_person_id = NEW.mentioned_person_id THEN
    RETURN NEW;
  END IF;

  sender_label := COALESCE(
    (SELECT inled_activity_email_sender_label(writer_person_id)),
    'Someone'
  );

  snippet := left(trim(regexp_replace(exp_rec.summary, '\s+', ' ', 'g')), 120);
  IF length(trim(exp_rec.summary)) > 120 THEN
    snippet := snippet || '…';
  END IF;
  IF snippet = '' THEN
    snippet := '—';
  END IF;

  IF exp_rec.expectation_type = 1 THEN
    kind := 'Talking point';
    activity_line := 'You were mentioned in a public talking point.';
  ELSE
    kind := 'Expectation';
    activity_line := 'You were added as a receiver on an expectation.';
  END IF;

  INSERT INTO activity_email_outbox (
    company_id,
    expectation_id,
    recipient_person_id,
    recipient_email,
    sender_person_id,
    sender_label,
    source_type,
    source_id,
    kind_label,
    activity_line,
    summary_snippet
  ) VALUES (
    exp_rec.company_id,
    NEW.expectation_id,
    NEW.mentioned_person_id,
    recip_email,
    writer_person_id,
    sender_label,
    'mention',
    NEW.id,
    kind,
    activity_line,
    snippet
  )
  ON CONFLICT ON CONSTRAINT uq_activity_email_outbox_source_recipient DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_mention_activity_emails ON expectation_mentions;
CREATE TRIGGER trg_enqueue_mention_activity_emails
  AFTER INSERT ON expectation_mentions
  FOR EACH ROW
  EXECUTE FUNCTION inled_enqueue_mention_activity_emails();

-- Optional immediate dispatch via pg_net (no-op if extension/settings missing).
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION inled_dispatch_activity_email_outbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  fn_url text;
  sr_key text;
BEGIN
  BEGIN
    fn_url := current_setting('app.activity_email_function_url', true);
    sr_key := current_setting('app.service_role_key', true);
  EXCEPTION WHEN OTHERS THEN
    RETURN NEW;
  END;

  IF fn_url IS NULL OR fn_url = '' OR sr_key IS NULL OR sr_key = '' THEN
    RETURN NEW;
  END IF;

  PERFORM net.http_post(
    url := fn_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || sr_key
    ),
    body := jsonb_build_object('outbox_id', NEW.id::text)
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_dispatch_activity_email_outbox ON activity_email_outbox;
CREATE TRIGGER trg_dispatch_activity_email_outbox
  AFTER INSERT ON activity_email_outbox
  FOR EACH ROW
  WHEN (NEW.status = 'pending')
  EXECUTE FUNCTION inled_dispatch_activity_email_outbox();
