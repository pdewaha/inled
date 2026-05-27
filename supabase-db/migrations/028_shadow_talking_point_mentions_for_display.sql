-- Private notepad @mentions are stored for UI (listing, sidebar filters) but never
-- notify others (see inled_enqueue_mention_activity_emails / changelog triggers).

DROP TRIGGER IF EXISTS trg_expectation_mentions_block_shadow_topic ON public.expectation_mentions;
DROP FUNCTION IF EXISTS public.inled_expectation_mentions_block_shadow_topic();

DROP TRIGGER IF EXISTS trg_expectation_mentions_purge_shadow_topic ON public.expectations;
DROP FUNCTION IF EXISTS public.inled_expectation_mentions_purge_shadow_topic();

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
          (e.expectation_type = 1 AND e.expectation_visibility IN (0, 1))
          OR (e.expectation_type = 0 AND e.expectation_visibility IN (0, 1))
        )
    )
  );
