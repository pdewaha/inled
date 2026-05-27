-- Row Level Security for Inled (Supabase / Postgres)
-- Apply after schema.sql on a project where tables already exist.
--
-- Model: auth.uid() links to people.auth_user_id; tenancy is people.company_id.
-- SECURITY DEFINER helpers bypass RLS on people so policies are not recursive.
--
-- Onboarding: companies may be discovered by email domain (JWT email); people
-- rows are created with auth_user_id = auth.uid() for join/create flows.

-- ---------------------------------------------------------------------------
-- Helper functions (SECURITY DEFINER; fixed search_path)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.inled_user_company_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.company_id
  FROM people p
  WHERE p.auth_user_id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.inled_user_person_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.id
  FROM people p
  WHERE p.auth_user_id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.inled_jwt_email_domain()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT lower(
    split_part(
      coalesce(nullif(trim(auth.jwt() ->> 'email'), ''), ''),
      '@',
      2
    )
  );
$$;

REVOKE ALL ON FUNCTION public.inled_user_company_ids() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.inled_user_person_ids() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.inled_jwt_email_domain() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inled_user_company_ids() TO authenticated;
GRANT EXECUTE ON FUNCTION public.inled_user_person_ids() TO authenticated;
GRANT EXECUTE ON FUNCTION public.inled_jwt_email_domain() TO authenticated;

CREATE OR REPLACE FUNCTION public.inled_jwt_email_normalized()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT lower(trim(coalesce(nullif(trim(auth.jwt() ->> 'email'), ''), '')));
$$;

REVOKE ALL ON FUNCTION public.inled_jwt_email_normalized() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inled_jwt_email_normalized() TO authenticated;

CREATE OR REPLACE FUNCTION public.inled_expectation_reader_may_select(
  p_expectation_id uuid,
  p_company_id uuid,
  p_writer_user_id uuid,
  p_expectation_visibility integer,
  p_target_person_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p_company_id IN (SELECT public.inled_user_company_ids())
    AND (
      p_writer_user_id = auth.uid()
      OR (
        p_expectation_visibility = 1
        AND (
          p_target_person_id IN (SELECT public.inled_user_person_ids())
          OR EXISTS (
            SELECT 1
            FROM expectation_mentions em
            WHERE em.expectation_id = p_expectation_id
              AND em.mentioned_person_id IN (SELECT public.inled_user_person_ids())
          )
        )
      )
    );
$$;

REVOKE ALL ON FUNCTION public.inled_expectation_reader_may_select(uuid, uuid, uuid, integer, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inled_expectation_reader_may_select(uuid, uuid, uuid, integer, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Enable RLS
-- ---------------------------------------------------------------------------

ALTER TABLE companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE people ENABLE ROW LEVEL SECURITY;
ALTER TABLE expectations ENABLE ROW LEVEL SECURITY;
ALTER TABLE expectation_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE expectation_tag_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE expectation_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_captures ENABLE ROW LEVEL SECURITY;
ALTER TABLE expectation_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE expectation_message_attachments ENABLE ROW LEVEL SECURITY;
ALTER TABLE expectation_message_reads ENABLE ROW LEVEL SECURITY;
ALTER TABLE expectation_changelog_reads ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- companies
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS inled_companies_select ON companies;
CREATE POLICY inled_companies_select ON companies
  FOR SELECT
  TO authenticated
  USING (
    id IN (SELECT public.inled_user_company_ids())
    OR (
      domain IS NOT NULL
      AND lower(domain) = public.inled_jwt_email_domain()
      AND public.inled_jwt_email_domain() <> ''
    )
  );

DROP POLICY IF EXISTS inled_companies_insert ON companies;
CREATE POLICY inled_companies_insert ON companies
  FOR INSERT
  TO authenticated
  WITH CHECK (created_by = auth.uid());

DROP POLICY IF EXISTS inled_companies_update ON companies;
CREATE POLICY inled_companies_update ON companies
  FOR UPDATE
  TO authenticated
  USING (id IN (SELECT public.inled_user_company_ids()))
  WITH CHECK (id IN (SELECT public.inled_user_company_ids()));

-- ---------------------------------------------------------------------------
-- people
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS inled_people_select ON people;
CREATE POLICY inled_people_select ON people
  FOR SELECT
  TO authenticated
  USING (
    company_id IN (SELECT public.inled_user_company_ids())
    OR auth_user_id = auth.uid()
    OR (
      auth_user_id IS NULL
      AND nullif(trim(lower(coalesce(email, ''))), '') =
          nullif(public.inled_jwt_email_normalized(), '')
      AND public.inled_jwt_email_normalized() <> ''
      AND EXISTS (
        SELECT 1
        FROM companies c
        WHERE c.id = company_id
          AND c.domain IS NOT NULL
          AND lower(c.domain) = public.inled_jwt_email_domain()
          AND public.inled_jwt_email_domain() <> ''
      )
    )
  );

DROP POLICY IF EXISTS inled_people_insert ON people;
CREATE POLICY inled_people_insert ON people
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (
      auth_user_id = auth.uid()
      AND (
        company_id IN (SELECT public.inled_user_company_ids())
        OR EXISTS (
          SELECT 1
          FROM companies c
          WHERE c.id = company_id
            AND c.domain IS NOT NULL
            AND lower(c.domain) = public.inled_jwt_email_domain()
            AND public.inled_jwt_email_domain() <> ''
        )
      )
    )
    OR (
      -- Placeholder person for @mentions / expectations before they sign up
      auth_user_id IS NULL
      AND company_id IN (SELECT public.inled_user_company_ids())
    )
  );

DROP POLICY IF EXISTS inled_people_update ON people;
CREATE POLICY inled_people_update ON people
  FOR UPDATE
  TO authenticated
  USING (
    company_id IN (SELECT public.inled_user_company_ids())
    OR (
      auth_user_id IS NULL
      AND nullif(trim(lower(coalesce(email, ''))), '') =
          nullif(public.inled_jwt_email_normalized(), '')
      AND public.inled_jwt_email_normalized() <> ''
      AND EXISTS (
        SELECT 1
        FROM companies c
        WHERE c.id = company_id
          AND c.domain IS NOT NULL
          AND lower(c.domain) = public.inled_jwt_email_domain()
          AND public.inled_jwt_email_domain() <> ''
      )
    )
  )
  WITH CHECK (
    company_id IN (SELECT public.inled_user_company_ids())
    OR (
      auth_user_id = auth.uid()
      AND EXISTS (
        SELECT 1
        FROM companies c
        WHERE c.id = company_id
          AND c.domain IS NOT NULL
          AND lower(c.domain) = public.inled_jwt_email_domain()
          AND public.inled_jwt_email_domain() <> ''
      )
    )
  );

-- Domain join / invite claim (bypasses RLS; see migrations 023 / 024).
CREATE OR REPLACE FUNCTION public.inled_claim_person_for_domain_join(
  p_company_id uuid,
  p_title text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_uid uuid;
  v_email text;
  v_domain text;
  v_company_domain text;
  v_local text;
  v_display text;
  v_handle text;
  pid uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  v_email := lower(trim(coalesce(nullif(trim(auth.jwt() ->> 'email'), ''), '')));
  IF v_email = '' OR position('@' IN v_email) = 0 THEN
    RAISE EXCEPTION 'jwt has no email' USING ERRCODE = '28000';
  END IF;

  v_domain := lower(split_part(v_email, '@', 2));

  SELECT lower(trim(c.domain))
  INTO v_company_domain
  FROM companies c
  WHERE c.id = p_company_id;

  IF v_company_domain IS NULL OR v_company_domain = '' THEN
    RAISE EXCEPTION 'company has no domain' USING ERRCODE = '28000';
  END IF;

  IF v_company_domain <> v_domain THEN
    RAISE EXCEPTION 'email domain does not match company domain' USING ERRCODE = '28000';
  END IF;

  UPDATE people
  SET
    auth_user_id = v_uid,
    updated_at = now(),
    title = COALESCE(NULLIF(trim(p_title), ''), title)
  WHERE company_id = p_company_id
    AND lower(trim(coalesce(email, ''))) = v_email
    AND (auth_user_id IS NULL OR auth_user_id = v_uid)
  RETURNING id INTO pid;

  IF pid IS NOT NULL THEN
    RETURN pid;
  END IF;

  v_local := split_part(v_email, '@', 1);
  IF length(v_local) = 0 THEN
    v_display := v_email;
  ELSE
    v_display := upper(substr(v_local, 1, 1)) || substr(v_local, 2);
  END IF;

  v_handle := lower(regexp_replace(v_local, '[^a-zA-Z0-9._-]', '', 'g'));
  IF v_handle IS NULL OR v_handle = '' THEN
    v_handle := 'user';
  END IF;

  INSERT INTO people (
    company_id,
    email,
    display_name,
    handle,
    title,
    auth_user_id,
    role,
    status
  )
  VALUES (
    p_company_id,
    v_email,
    v_display,
    v_handle,
    nullif(trim(p_title), ''),
    v_uid,
    0,
    1
  )
  RETURNING id INTO pid;

  RETURN pid;

EXCEPTION
  WHEN unique_violation THEN
    UPDATE people
    SET
      auth_user_id = v_uid,
      updated_at = now(),
      title = COALESCE(NULLIF(trim(p_title), ''), title)
    WHERE company_id = p_company_id
      AND lower(trim(coalesce(email, ''))) = v_email
      AND (auth_user_id IS NULL OR auth_user_id = v_uid)
    RETURNING id INTO pid;

    IF pid IS NOT NULL THEN
      RETURN pid;
    END IF;
    RAISE;
END;
$$;

REVOKE ALL ON FUNCTION public.inled_claim_person_for_domain_join(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inled_claim_person_for_domain_join(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- invites
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS inled_invites_select ON invites;
CREATE POLICY inled_invites_select ON invites
  FOR SELECT
  TO authenticated
  USING (company_id IN (SELECT public.inled_user_company_ids()));

DROP POLICY IF EXISTS inled_invites_insert ON invites;
CREATE POLICY inled_invites_insert ON invites
  FOR INSERT
  TO authenticated
  WITH CHECK (
    company_id IN (SELECT public.inled_user_company_ids())
    AND invited_by_user_id = auth.uid()
  );

DROP POLICY IF EXISTS inled_invites_update ON invites;
CREATE POLICY inled_invites_update ON invites
  FOR UPDATE
  TO authenticated
  USING (company_id IN (SELECT public.inled_user_company_ids()))
  WITH CHECK (company_id IN (SELECT public.inled_user_company_ids()));

DROP POLICY IF EXISTS inled_invites_delete ON invites;
CREATE POLICY inled_invites_delete ON invites
  FOR DELETE
  TO authenticated
  USING (company_id IN (SELECT public.inled_user_company_ids()));

-- ---------------------------------------------------------------------------
-- expectations
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS inled_expectations_select ON expectations;
CREATE POLICY inled_expectations_select ON expectations
  FOR SELECT
  TO authenticated
  USING (
    public.inled_expectation_reader_may_select(
      id,
      company_id,
      writer_user_id,
      expectation_visibility,
      target_person_id
    )
  );

DROP POLICY IF EXISTS inled_expectations_insert ON expectations;
CREATE POLICY inled_expectations_insert ON expectations
  FOR INSERT
  TO authenticated
  WITH CHECK (
    company_id IN (SELECT public.inled_user_company_ids())
    AND writer_user_id = auth.uid()
  );

DROP POLICY IF EXISTS inled_expectations_update ON expectations;
CREATE POLICY inled_expectations_update ON expectations
  FOR UPDATE
  TO authenticated
  USING (company_id IN (SELECT public.inled_user_company_ids()))
  WITH CHECK (company_id IN (SELECT public.inled_user_company_ids()));

DROP POLICY IF EXISTS inled_expectations_delete ON expectations;
CREATE POLICY inled_expectations_delete ON expectations
  FOR DELETE
  TO authenticated
  USING (
    company_id IN (SELECT public.inled_user_company_ids())
    AND writer_user_id = auth.uid()
  );

-- ---------------------------------------------------------------------------
-- expectation_tags
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS inled_expectation_tags_select ON expectation_tags;
CREATE POLICY inled_expectation_tags_select ON expectation_tags
  FOR SELECT
  TO authenticated
  USING (company_id IN (SELECT public.inled_user_company_ids()));

DROP POLICY IF EXISTS inled_expectation_tags_insert ON expectation_tags;
CREATE POLICY inled_expectation_tags_insert ON expectation_tags
  FOR INSERT
  TO authenticated
  WITH CHECK (company_id IN (SELECT public.inled_user_company_ids()));

DROP POLICY IF EXISTS inled_expectation_tags_update ON expectation_tags;
CREATE POLICY inled_expectation_tags_update ON expectation_tags
  FOR UPDATE
  TO authenticated
  USING (company_id IN (SELECT public.inled_user_company_ids()))
  WITH CHECK (company_id IN (SELECT public.inled_user_company_ids()));

DROP POLICY IF EXISTS inled_expectation_tags_delete ON expectation_tags;
CREATE POLICY inled_expectation_tags_delete ON expectation_tags
  FOR DELETE
  TO authenticated
  USING (company_id IN (SELECT public.inled_user_company_ids()));

-- ---------------------------------------------------------------------------
-- expectation_tag_links
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS inled_expectation_tag_links_select ON expectation_tag_links;
CREATE POLICY inled_expectation_tag_links_select ON expectation_tag_links
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM expectations e
      WHERE e.id = expectation_id
        AND public.inled_expectation_reader_may_select(
          e.id,
          e.company_id,
          e.writer_user_id,
          e.expectation_visibility,
          e.target_person_id
        )
    )
  );

DROP POLICY IF EXISTS inled_expectation_tag_links_insert ON expectation_tag_links;
CREATE POLICY inled_expectation_tag_links_insert ON expectation_tag_links
  FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM expectations e
      WHERE e.id = expectation_id
        AND e.company_id IN (SELECT public.inled_user_company_ids())
    )
    AND EXISTS (
      SELECT 1
      FROM expectation_tags t
      WHERE t.id = tag_id
        AND t.company_id IN (SELECT public.inled_user_company_ids())
    )
  );

DROP POLICY IF EXISTS inled_expectation_tag_links_delete ON expectation_tag_links;
CREATE POLICY inled_expectation_tag_links_delete ON expectation_tag_links
  FOR DELETE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM expectations e
      WHERE e.id = expectation_id
        AND e.company_id IN (SELECT public.inled_user_company_ids())
    )
  );

-- ---------------------------------------------------------------------------
-- expectation_events
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS inled_expectation_events_select ON expectation_events;
CREATE POLICY inled_expectation_events_select ON expectation_events
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM expectations e
      WHERE e.id = expectation_id
        AND public.inled_expectation_reader_may_select(
          e.id,
          e.company_id,
          e.writer_user_id,
          e.expectation_visibility,
          e.target_person_id
        )
    )
  );

DROP POLICY IF EXISTS inled_expectation_events_insert ON expectation_events;
CREATE POLICY inled_expectation_events_insert ON expectation_events
  FOR INSERT
  TO authenticated
  WITH CHECK (company_id IN (SELECT public.inled_user_company_ids()));

-- ---------------------------------------------------------------------------
-- ledger_captures
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS inled_ledger_captures_select ON ledger_captures;
CREATE POLICY inled_ledger_captures_select ON ledger_captures
  FOR SELECT
  TO authenticated
  USING (company_id IN (SELECT public.inled_user_company_ids()));

DROP POLICY IF EXISTS inled_ledger_captures_insert ON ledger_captures;
CREATE POLICY inled_ledger_captures_insert ON ledger_captures
  FOR INSERT
  TO authenticated
  WITH CHECK (company_id IN (SELECT public.inled_user_company_ids()));

DROP POLICY IF EXISTS inled_ledger_captures_delete ON ledger_captures;
CREATE POLICY inled_ledger_captures_delete ON ledger_captures
  FOR DELETE
  TO authenticated
  USING (company_id IN (SELECT public.inled_user_company_ids()));

-- ---------------------------------------------------------------------------
-- expectation_messages
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS inled_expectation_messages_select ON expectation_messages;
CREATE POLICY inled_expectation_messages_select ON expectation_messages
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM expectations e
      WHERE e.id = expectation_id
        AND public.inled_expectation_reader_may_select(
          e.id,
          e.company_id,
          e.writer_user_id,
          e.expectation_visibility,
          e.target_person_id
        )
    )
  );

DROP POLICY IF EXISTS inled_expectation_messages_insert ON expectation_messages;
CREATE POLICY inled_expectation_messages_insert ON expectation_messages
  FOR INSERT
  TO authenticated
  WITH CHECK (
    company_id IN (SELECT public.inled_user_company_ids())
    AND sender_person_id IN (SELECT public.inled_user_person_ids())
  );

DROP POLICY IF EXISTS inled_expectation_messages_update ON expectation_messages;
CREATE POLICY inled_expectation_messages_update ON expectation_messages
  FOR UPDATE
  TO authenticated
  USING (company_id IN (SELECT public.inled_user_company_ids()))
  WITH CHECK (company_id IN (SELECT public.inled_user_company_ids()));

DROP POLICY IF EXISTS inled_expectation_messages_delete ON expectation_messages;
CREATE POLICY inled_expectation_messages_delete ON expectation_messages
  FOR DELETE
  TO authenticated
  USING (company_id IN (SELECT public.inled_user_company_ids()));

-- ---------------------------------------------------------------------------
-- expectation_message_attachments
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS inled_expectation_message_attachments_select
  ON expectation_message_attachments;
CREATE POLICY inled_expectation_message_attachments_select
  ON expectation_message_attachments
  FOR SELECT
  TO authenticated
  USING (company_id IN (SELECT public.inled_user_company_ids()));

DROP POLICY IF EXISTS inled_expectation_message_attachments_insert
  ON expectation_message_attachments;
CREATE POLICY inled_expectation_message_attachments_insert
  ON expectation_message_attachments
  FOR INSERT
  TO authenticated
  WITH CHECK (company_id IN (SELECT public.inled_user_company_ids()));

DROP POLICY IF EXISTS inled_expectation_message_attachments_delete
  ON expectation_message_attachments;
CREATE POLICY inled_expectation_message_attachments_delete
  ON expectation_message_attachments
  FOR DELETE
  TO authenticated
  USING (company_id IN (SELECT public.inled_user_company_ids()));

-- ---------------------------------------------------------------------------
-- expectation_message_reads (chat read receipts; reader or message sender)
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS inled_expectation_message_reads_select
  ON expectation_message_reads;
CREATE POLICY inled_expectation_message_reads_select
  ON expectation_message_reads
  FOR SELECT
  TO authenticated
  USING (
    company_id IN (SELECT public.inled_user_company_ids())
    AND (
      reader_person_id IN (SELECT public.inled_user_person_ids())
      OR EXISTS (
        SELECT 1
        FROM expectation_messages em
        WHERE em.id = expectation_message_reads.message_id
          AND em.sender_person_id IN (SELECT public.inled_user_person_ids())
      )
    )
  );

DROP POLICY IF EXISTS inled_expectation_message_reads_insert
  ON expectation_message_reads;
CREATE POLICY inled_expectation_message_reads_insert
  ON expectation_message_reads
  FOR INSERT
  TO authenticated
  WITH CHECK (
    company_id IN (SELECT public.inled_user_company_ids())
    AND reader_person_id IN (SELECT public.inled_user_person_ids())
    AND EXISTS (
      SELECT 1
      FROM expectation_messages em
      WHERE em.id = expectation_message_reads.message_id
        AND em.company_id = expectation_message_reads.company_id
        AND em.sender_person_id <> expectation_message_reads.reader_person_id
    )
  );

GRANT SELECT, INSERT ON TABLE public.expectation_message_reads TO authenticated;
GRANT ALL ON TABLE public.expectation_message_reads TO service_role;

-- ---------------------------------------------------------------------------
-- expectation_changelog_reads (per-user changelog read watermark)
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS inled_expectation_changelog_reads_select
  ON expectation_changelog_reads;
CREATE POLICY inled_expectation_changelog_reads_select
  ON expectation_changelog_reads
  FOR SELECT
  TO authenticated
  USING (
    company_id IN (SELECT public.inled_user_company_ids())
    AND reader_person_id IN (SELECT public.inled_user_person_ids())
  );

DROP POLICY IF EXISTS inled_expectation_changelog_reads_insert
  ON expectation_changelog_reads;
CREATE POLICY inled_expectation_changelog_reads_insert
  ON expectation_changelog_reads
  FOR INSERT
  TO authenticated
  WITH CHECK (
    company_id IN (SELECT public.inled_user_company_ids())
    AND reader_person_id IN (SELECT public.inled_user_person_ids())
  );

DROP POLICY IF EXISTS inled_expectation_changelog_reads_update
  ON expectation_changelog_reads;
CREATE POLICY inled_expectation_changelog_reads_update
  ON expectation_changelog_reads
  FOR UPDATE
  TO authenticated
  USING (
    company_id IN (SELECT public.inled_user_company_ids())
    AND reader_person_id IN (SELECT public.inled_user_person_ids())
  )
  WITH CHECK (
    company_id IN (SELECT public.inled_user_company_ids())
    AND reader_person_id IN (SELECT public.inled_user_person_ids())
  );

DROP POLICY IF EXISTS inled_expectation_changelog_reads_delete
  ON expectation_changelog_reads;
CREATE POLICY inled_expectation_changelog_reads_delete
  ON expectation_changelog_reads
  FOR DELETE
  TO authenticated
  USING (
    company_id IN (SELECT public.inled_user_company_ids())
    AND reader_person_id IN (SELECT public.inled_user_person_ids())
  );

-- ---------------------------------------------------------------------------
-- expectation_mentions (@people on talking points + co-receivers on expectations;
-- primary expectation receiver remains expectations.target_person_id)
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS inled_expectation_mentions_select ON expectation_mentions;
CREATE POLICY inled_expectation_mentions_select ON expectation_mentions
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM expectations e
      WHERE e.id = expectation_id
        AND e.company_id = company_id
        AND public.inled_expectation_reader_may_select(
          e.id,
          e.company_id,
          e.writer_user_id,
          e.expectation_visibility,
          e.target_person_id
        )
    )
  );

DROP POLICY IF EXISTS inled_expectation_mentions_insert ON expectation_mentions;
CREATE POLICY inled_expectation_mentions_insert ON expectation_mentions
  FOR INSERT
  TO authenticated
  WITH CHECK (
    company_id IN (SELECT public.inled_user_company_ids())
    AND EXISTS (
      SELECT 1
      FROM expectations e
      WHERE e.id = expectation_id
        AND e.company_id = company_id
        AND e.writer_user_id = auth.uid()
        AND (
          (e.expectation_type = 1 AND e.expectation_visibility IN (0, 1))
          OR (e.expectation_type = 0 AND e.expectation_visibility IN (0, 1))
        )
    )
  );

DROP POLICY IF EXISTS inled_expectation_mentions_delete ON expectation_mentions;
CREATE POLICY inled_expectation_mentions_delete ON expectation_mentions
  FOR DELETE
  TO authenticated
  USING (
    company_id IN (SELECT public.inled_user_company_ids())
    AND EXISTS (
      SELECT 1
      FROM expectations e
      WHERE e.id = expectation_id
        AND e.writer_user_id = auth.uid()
        AND e.expectation_type IN (0, 1)
    )
  );

-- activity_email_outbox (migration 010): RLS enabled, no authenticated policies.
-- Rows are written by SECURITY DEFINER triggers; sent by the send-activity-email Edge Function (service role).
