-- Prod fix: migration 005 enabled RLS on expectation_message_reads but grants/policies
-- may not have been applied. Without these, PostgREST returns 42501 on embed/select.

GRANT SELECT, INSERT ON TABLE public.expectation_message_reads TO authenticated;
GRANT ALL ON TABLE public.expectation_message_reads TO service_role;

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
