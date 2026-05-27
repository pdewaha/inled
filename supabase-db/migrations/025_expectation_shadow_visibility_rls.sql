-- Shadow (expectation_visibility = 0) drafts are writer-only until published (echo = 1).
-- Receivers and co-@mentions must not read shadow rows via company-wide SELECT.

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
