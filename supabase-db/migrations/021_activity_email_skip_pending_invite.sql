-- When a colleague gets an invite email (lists open expectations/talking points),
-- skip redundant "Created a new expectation/talking point" activity mail.

CREATE OR REPLACE FUNCTION public.inled_recipient_has_pending_invite(
  p_company_id uuid,
  p_person_id uuid,
  p_email text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM invites i
    WHERE i.company_id = p_company_id
      AND i.status = 0
      AND i.expires_at > now()
      AND (
        lower(trim(i.email)) = lower(trim(p_email))
        OR i.token_hash LIKE 'personalized:' || p_person_id::text || ':%'
      )
  );
$$;

REVOKE ALL ON FUNCTION public.inled_recipient_has_pending_invite(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inled_recipient_has_pending_invite(uuid, uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.inled_enqueue_changelog_activity_emails()
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
  IF is_topic AND exp_rec.expectation_visibility = 0 THEN
    RETURN NEW;
  END IF;

  sender_label := inled_activity_email_sender_label(NEW.sender_person_id);

  IF NEW.type = 15 THEN
    activity_line :=
      'Requested an update — consider progress, deadline, or status.';
  ELSE
    activity_line := inled_changelog_email_activity_line(
      NEW.type,
      NEW.message_text,
      is_topic
    );
  END IF;

  FOR recip IN
    SELECT * FROM inled_activity_email_recipients(NEW.expectation_id, NEW.sender_person_id)
  LOOP
    IF NEW.type <> 15
       AND (
         lower_msg LIKE 'created a new expectation%'
         OR lower_msg LIKE 'created a new talking point%'
       ) THEN
      IF EXISTS (
        SELECT 1
        FROM people pw
        WHERE pw.id = recip.person_id
          AND pw.auth_user_id = exp_rec.writer_user_id
          AND pw.company_id = exp_rec.company_id
      ) THEN
        CONTINUE;
      END IF;

      -- Invite email already lists waiting items for this colleague.
      IF inled_recipient_has_pending_invite(
        exp_rec.company_id,
        recip.person_id,
        recip.email
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

COMMENT ON FUNCTION public.inled_enqueue_changelog_activity_emails() IS
  'Changelog activity mail; skips author on create; skips pending invitees on create (invite mail lists items).';
