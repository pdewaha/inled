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
  );

DROP POLICY IF EXISTS inled_people_insert ON people;
CREATE POLICY inled_people_insert ON people
  FOR INSERT
  TO authenticated
  WITH CHECK (
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
  );

DROP POLICY IF EXISTS inled_people_update ON people;
CREATE POLICY inled_people_update ON people
  FOR UPDATE
  TO authenticated
  USING (company_id IN (SELECT public.inled_user_company_ids()))
  WITH CHECK (company_id IN (SELECT public.inled_user_company_ids()));

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
  USING (company_id IN (SELECT public.inled_user_company_ids()));

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
        AND e.company_id IN (SELECT public.inled_user_company_ids())
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
  USING (company_id IN (SELECT public.inled_user_company_ids()));

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
  USING (company_id IN (SELECT public.inled_user_company_ids()));

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
