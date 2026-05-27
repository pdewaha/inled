-- Private (shadow) talking points must never notify others: no mention rows,
-- no mention mail, no changelog mail (already skipped in enqueue functions).

-- Remove stale @mention rows on private talking points.
DELETE FROM public.expectation_mentions m
USING public.expectations e
WHERE e.id = m.expectation_id
  AND e.company_id = m.company_id
  AND e.expectation_type = 1
  AND e.expectation_visibility = 0;

DROP POLICY IF EXISTS inled_expectation_mentions_insert ON public.expectation_mentions;
CREATE POLICY inled_expectation_mentions_insert ON public.expectation_mentions
  FOR INSERT
  TO authenticated
  WITH CHECK (
    company_id IN (SELECT public.inled_user_company_ids())
    AND EXISTS (
      SELECT 1
      FROM public.expectations e
      WHERE e.id = expectation_id
        AND e.company_id = company_id
        AND e.writer_user_id = auth.uid()
        AND (
          (e.expectation_type = 1 AND e.expectation_visibility = 1)
          OR (e.expectation_type = 0 AND e.expectation_visibility IN (0, 1))
        )
    )
  );

CREATE OR REPLACE FUNCTION public.inled_expectation_mentions_block_shadow_topic()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.expectations e
    WHERE e.id = NEW.expectation_id
      AND e.company_id = NEW.company_id
      AND e.expectation_type = 1
      AND e.expectation_visibility = 0
  ) THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_expectation_mentions_block_shadow_topic ON public.expectation_mentions;
CREATE TRIGGER trg_expectation_mentions_block_shadow_topic
  BEFORE INSERT ON public.expectation_mentions
  FOR EACH ROW
  EXECUTE FUNCTION public.inled_expectation_mentions_block_shadow_topic();

CREATE OR REPLACE FUNCTION public.inled_expectation_mentions_purge_shadow_topic()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.expectation_type = 1 AND NEW.expectation_visibility = 0 THEN
    DELETE FROM public.expectation_mentions m
    WHERE m.expectation_id = NEW.id
      AND m.company_id = NEW.company_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_expectation_mentions_purge_shadow_topic ON public.expectations;
CREATE TRIGGER trg_expectation_mentions_purge_shadow_topic
  AFTER INSERT OR UPDATE OF expectation_visibility ON public.expectations
  FOR EACH ROW
  EXECUTE FUNCTION public.inled_expectation_mentions_purge_shadow_topic();

-- Belt-and-suspenders on mention mail (echo expectations only; talking points use publish changelog).
CREATE OR REPLACE FUNCTION public.inled_enqueue_mention_activity_emails()
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
  FROM public.expectations e
  WHERE e.id = NEW.expectation_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF exp_rec.expectation_visibility <> 1 THEN
    RETURN NEW;
  END IF;

  IF exp_rec.expectation_type = 1 THEN
    RETURN NEW;
  END IF;

  IF NEW.mentioned_person_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT NULLIF(trim(p.email), '')
  INTO recip_email
  FROM public.people p
  WHERE p.id = NEW.mentioned_person_id;

  IF recip_email IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT p.id
  INTO writer_person_id
  FROM public.people p
  WHERE p.auth_user_id = exp_rec.writer_user_id
    AND p.company_id = exp_rec.company_id
  LIMIT 1;

  IF writer_person_id IS NOT NULL AND writer_person_id = NEW.mentioned_person_id THEN
    RETURN NEW;
  END IF;

  sender_label := COALESCE(
    (SELECT public.inled_activity_email_sender_label(writer_person_id)),
    'Someone'
  );

  snippet := left(trim(regexp_replace(exp_rec.summary, '\s+', ' ', 'g')), 120);
  IF length(trim(exp_rec.summary)) > 120 THEN
    snippet := snippet || '…';
  END IF;
  IF snippet = '' THEN
    snippet := '—';
  END IF;

  kind := 'Expectation';
  activity_line := 'You were added as a receiver on an expectation.';

  INSERT INTO public.activity_email_outbox (
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

COMMENT ON FUNCTION public.inled_enqueue_mention_activity_emails() IS
  'Mention activity mail for published expectations only; talking points use publish changelog.';
